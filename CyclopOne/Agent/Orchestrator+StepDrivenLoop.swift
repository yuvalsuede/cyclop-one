import Foundation

// MARK: - Orchestrator Step-Driven Loop
// Step-by-step execution loop for planned tasks.
// Extracted from Orchestrator.swift in Sprint 1 (Refactoring).

extension Orchestrator {

    // MARK: - M2: Step-Driven Iteration Loop

    /// Step-driven iteration loop. Executes each plan step sequentially,
    /// injecting only the current step's instruction into the executor.
    /// Falls back to the flat loop if anything goes structurally wrong.
    func runStepDrivenLoop(
        runId: String,
        command: String,
        completionToken: String,
        plan: ExecutionPlan,
        startIteration: Int,
        totalInput: Int,
        totalOutput: Int,
        journal: RunJournal,
        agentLoop: AgentLoop,
        replyChannel: (any ReplyChannel)?,
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        onMessage: @Sendable @escaping (ChatMessage) -> Void,
        onConfirmationNeeded: @Sendable @escaping (String) async -> Bool,
        observer: (any AgentObserver)? = nil
    ) async -> RunResult {
        defer { lifecycle.cleanupCancelState() }  // M6: Always clean up cancel state

        var totalInput = totalInput
        var totalOutput = totalOutput
        var iteration = startIteration
        var anyToolCallsExecuted = false
        var anyVisualToolCalls = false
        var verificationInputTokens = 0
        var verificationOutputTokens = 0
        // Plan reference for mid-run revisions
        let mutablePlan = plan

        NSLog("CyclopOne [Orchestrator]: Starting step-driven loop with %d steps", mutablePlan.steps.count)

        while stepMachine.currentStepIndex < mutablePlan.steps.count {
            let step = mutablePlan.steps[stepMachine.currentStepIndex]
            stepMachine.currentStepIterations = 0
            stepMachine.currentAlternativeIndex = 0

            NSLog("CyclopOne [Orchestrator]: Starting step %d/%d: %@",
                  step.id + 1, mutablePlan.steps.count, step.title)

            // --- Dependency Gate ---
            if let blockReason = stepMachine.canProceedToStep(step) {
                let crit = stepMachine.effectiveCriticality(of: step)
                NSLog("CyclopOne [Orchestrator]: Step %d blocked: %@", step.id + 1, blockReason)
                if crit == .critical {
                    let abortReason = "Critical step \(step.id + 1) ('\(step.title)') blocked by dependency: \(blockReason). Aborting."
                    return await abortStepDrivenRun(
                        runId: runId, reason: abortReason, iteration: iteration,
                        totalInput: totalInput, totalOutput: totalOutput,
                        verificationInputTokens: verificationInputTokens,
                        verificationOutputTokens: verificationOutputTokens,
                        journal: journal, replyChannel: replyChannel,
                        onStateChange: onStateChange, onMessage: onMessage
                    )
                }
                // Non-critical: skip this step
                stepMachine.stepOutcomes.append((step.id, .skipped(reason: "Dependency not met: \(blockReason)")))
                NSLog("CyclopOne [Orchestrator]: Skipping step %d (dependency not met, non-critical)", step.id + 1)
                stepMachine.currentStepIndex += 1
                continue
            }

            // --- Confirmation Gate ---
            if step.requiresConfirmation {
                let confirmMsg = "Step \(step.id + 1): \(step.title)\n\n\(step.action)\n\nProceed?"
                let approved = await onConfirmationNeeded(confirmMsg)
                if !approved {
                    stepMachine.stepOutcomes.append((step.id, .skipped(reason: "User denied")))
                    await journal.append(.fail(reason: "Step \(step.id + 1) skipped (user denied confirmation)"))
                    if let rc = replyChannel {
                        await rc.sendText("Step \(step.id + 1) skipped (user denied).")
                    }
                    stepMachine.currentStepIndex += 1
                    continue
                }
            }

            // --- Inject Current Step Instruction ---
            let stepInstruction = stepMachine.buildStepInstruction(step: step, plan: mutablePlan, stepOutcomes: stepMachine.stepOutcomes.map { ($0.stepId, $0.outcome) })
            await agentLoop.setCurrentStepInstruction(stepInstruction)

            // Inject a user-role step transition message for steps after the first.
            if step.id > 0 {
                await agentLoop.injectStepTransitionMessage(
                    stepIndex: step.id,
                    totalSteps: mutablePlan.steps.count,
                    stepTitle: step.title
                )
            }

            // M3: Fire step start observer event
            ObserverNotifier.notifyStepStart(observer, stepIndex: step.id, totalSteps: mutablePlan.steps.count, title: step.title)
            if observer == nil, let rc = replyChannel {
                await rc.sendText("Step \(step.id + 1)/\(mutablePlan.steps.count): \(step.title)")
            }

            // --- Execute Step (inner iteration loop) ---
            var stepComplete = false
            while stepMachine.currentStepIterations < step.maxIterations && iteration < runConfig.maxIterations {
                iteration += 1
                lifecycle.currentIteration = iteration
                stepMachine.currentStepIterations += 1
                let iterStartTime = Date()

                // Shared pre-iteration checks
                let preCheck = await runPreIterationChecks(
                    runId: runId, iteration: iteration,
                    totalInput: totalInput, totalOutput: totalOutput,
                    journal: journal, agentLoop: agentLoop, replyChannel: replyChannel,
                    onStateChange: onStateChange, onMessage: onMessage
                )
                if case .earlyExit(let result) = preCheck { return result }

                // Shared iteration execution with retry
                let taskResult = await executeAndAwaitIteration(
                    runId: runId, iteration: iteration,
                    totalInput: totalInput, totalOutput: totalOutput,
                    journal: journal, agentLoop: agentLoop,
                    onStateChange: onStateChange, onMessage: onMessage,
                    onConfirmationNeeded: onConfirmationNeeded, observer: observer
                )
                let iterResult: IterationResult
                switch taskResult {
                case .earlyExit(let result): return result
                case .success(let r): iterResult = r
                }

                totalInput += iterResult.inputTokens
                totalOutput += iterResult.outputTokens

                // Shared post-iteration processing
                await runPostIterationProcessing(
                    iterResult: iterResult, iteration: iteration,
                    iterStartTime: iterStartTime, journal: journal
                )

                // Track tool call execution
                if iterResult.hasMoreWork {
                    anyToolCallsExecuted = true
                    if iterResult.hasVisualToolCalls {
                        anyVisualToolCalls = true
                    }
                }

                // --- Check completion within this step ---
                let completionTokenFound = stepMachine.containsCompletionToken(iterResult.textContent)
                let claudeIndicatedDone = !iterResult.hasMoreWork

                if completionTokenFound || claudeIndicatedDone {
                    // Agent thinks this step is done -- validate outcome
                    let outcome = stepMachine.validateStepOutcome(
                        step: step,
                        textContent: iterResult.textContent
                    )
                    stepMachine.stepOutcomes.append((step.id, outcome))

                    switch outcome {
                    case .succeeded:
                        NSLog("CyclopOne [Orchestrator]: Step %d succeeded", step.id + 1)
                        // Mid-step verification for critical steps with visual tools
                        if step.criticality == .critical && anyVisualToolCalls {
                            let midVerify = await runMidStepVerification(
                                step: step, plan: mutablePlan, command: command,
                                textContent: iterResult.textContent,
                                screenshot: iterResult.screenshot,
                                agentLoop: agentLoop, onMessage: onMessage
                            )
                            verificationInputTokens += midVerify.inputTokens
                            verificationOutputTokens += midVerify.outputTokens
                            if !midVerify.passed {
                                // Remove the succeeded outcome and retry
                                if let lastIdx = stepMachine.stepOutcomes.lastIndex(where: { $0.stepId == step.id }) {
                                    stepMachine.stepOutcomes.remove(at: lastIdx)
                                }
                                NSLog("CyclopOne [Orchestrator]: Mid-step verification failed for step %d, retrying", step.id + 1)
                                await agentLoop.injectVerificationFeedback(
                                    "Mid-step check: Step \(step.id + 1) ('\(step.title)') needs correction. \(midVerify.reason). Try again."
                                )
                                break  // Continue inner loop
                            }
                        }
                        stepComplete = true

                    case .uncertain:
                        NSLog("CyclopOne [Orchestrator]: Step %d uncertain, proceeding", step.id + 1)
                        stepComplete = true

                    case .failed(let reason):
                        let crit = stepMachine.effectiveCriticality(of: step)
                        NSLog("CyclopOne [Orchestrator]: Step %d failed (%@): %@", step.id + 1, crit.rawValue, reason)

                        // Try alternative approaches before declaring failure
                        if let alternatives = step.alternativeApproaches,
                           stepMachine.currentAlternativeIndex < alternatives.count {
                            let altIdx = stepMachine.currentAlternativeIndex
                            let altApproach = alternatives[altIdx]
                            stepMachine.currentAlternativeIndex += 1
                            NSLog("CyclopOne [Orchestrator]: Step %d primary failed, trying alternative %d/%d: %@",
                                  step.id + 1, altIdx + 1, alternatives.count, altApproach)
                            if let lastIdx = stepMachine.stepOutcomes.lastIndex(where: { $0.stepId == step.id }) {
                                stepMachine.stepOutcomes.remove(at: lastIdx)
                            }
                            let altInstruction = "ALTERNATIVE APPROACH for step \(step.id + 1): The previous approach failed (\(reason)). Try this instead: \(altApproach)"
                            await agentLoop.injectBrainGuidance(altInstruction)
                            stepMachine.clearStuckTracking()
                            break
                        }

                        if crit == .critical {
                            let abortReason = "Critical step \(step.id + 1) ('\(step.title)') failed: \(reason). Aborting to prevent cascading errors."
                            return await abortStepDrivenRun(
                                runId: runId, reason: abortReason, iteration: iteration,
                                totalInput: totalInput, totalOutput: totalOutput,
                                verificationInputTokens: verificationInputTokens,
                                verificationOutputTokens: verificationOutputTokens,
                                journal: journal, replyChannel: replyChannel,
                                onStateChange: onStateChange, onMessage: onMessage
                            )
                        }
                        stepComplete = true

                    case .skipped:
                        stepComplete = true
                    }

                    if stepComplete { break }
                }

                // --- Per-step stuck detection ---
                if stepMachine.currentStepIterations >= step.maxIterations {
                    // Before declaring failure, try alternative approaches
                    if let alternatives = step.alternativeApproaches,
                       stepMachine.currentAlternativeIndex < alternatives.count {
                        let altIdx = stepMachine.currentAlternativeIndex
                        let altApproach = alternatives[altIdx]
                        stepMachine.currentAlternativeIndex += 1
                        NSLog("CyclopOne [Orchestrator]: Step %d exhausted iterations, trying alternative %d/%d: %@",
                              step.id + 1, altIdx + 1, alternatives.count, altApproach)
                        let altInstruction = "ALTERNATIVE APPROACH for step \(step.id + 1): The previous approach exhausted its iteration budget. Try this instead: \(altApproach)"
                        await agentLoop.injectBrainGuidance(altInstruction)
                        stepMachine.clearStuckTracking()
                        stepMachine.currentStepIterations = 0
                        stepMachine.hasEscalatedToBrain = false
                        continue
                    }

                    let crit = stepMachine.effectiveCriticality(of: step)
                    NSLog("CyclopOne [Orchestrator]: Step %d exhausted maxIterations (%d), criticality=%@",
                          step.id + 1, step.maxIterations, crit.rawValue)
                    let outcome = StepOutcome.failed(reason: "Exceeded max iterations for step")
                    stepMachine.stepOutcomes.append((step.id, outcome))
                    if crit == .critical {
                        let abortReason = "Critical step \(step.id + 1) ('\(step.title)') exceeded max iterations. Aborting to prevent wrong-field input."
                        return await abortStepDrivenRun(
                            runId: runId, reason: abortReason, iteration: iteration,
                            totalInput: totalInput, totalOutput: totalOutput,
                            verificationInputTokens: verificationInputTokens,
                            verificationOutputTokens: verificationOutputTokens,
                            journal: journal, replyChannel: replyChannel,
                            onStateChange: onStateChange, onMessage: onMessage
                        )
                    }
                    stepComplete = true
                    break
                }

                // Global stuck detection (safety net)
                if !iterResult.hasMoreWork, iteration >= runConfig.stuckThreshold, let stuckReason = stepMachine.detectStuck() {
                    if !stepMachine.hasEscalatedToBrain {
                        stepMachine.hasEscalatedToBrain = true
                        let stepContext = " at step \(step.id + 1)"
                        await consultBrainForStuck(
                            command: command,
                            stuckReason: stuckReason,
                            iteration: iteration,
                            stepInfo: stepContext,
                            journal: journal,
                            agentLoop: agentLoop,
                            onMessage: onMessage
                        )
                        stepMachine.clearStuckTracking()
                        continue
                    }

                    // Already consulted brain and still stuck -- terminate step
                    let crit = stepMachine.effectiveCriticality(of: step)
                    NSLog("CyclopOne [Orchestrator]: Still stuck after brain consultation, ending step %d (criticality=%@)", step.id + 1, crit.rawValue)
                    let outcome = StepOutcome.failed(reason: stuckReason)
                    stepMachine.stepOutcomes.append((step.id, outcome))
                    if crit == .critical {
                        let abortReason = "Critical step \(step.id + 1) ('\(step.title)') stuck after brain consultation: \(stuckReason). Aborting."
                        return await abortStepDrivenRun(
                            runId: runId, reason: abortReason, iteration: iteration,
                            totalInput: totalInput, totalOutput: totalOutput,
                            verificationInputTokens: verificationInputTokens,
                            verificationOutputTokens: verificationOutputTokens,
                            journal: journal, replyChannel: replyChannel,
                            onStateChange: onStateChange, onMessage: onMessage
                        )
                    }
                    stepComplete = true
                    break
                }

                await journal.append(.iterationEnd(iteration: iteration, screenshot: nil, verificationScore: nil))
            }

            // M3: Fire step complete observer event
            if stepComplete {
                let outcomeDesc = stepMachine.stepOutcomes.last.map { stepMachine.describeOutcome($0.outcome) } ?? "unknown"
                ObserverNotifier.notifyStepComplete(
                    observer,
                    stepIndex: step.id,
                    totalSteps: mutablePlan.steps.count,
                    title: step.title,
                    outcome: outcomeDesc,
                    screenshot: stepMachine.preActionScreenshot?.imageData
                )
            }

            // Mid-run replanning: when a non-critical step fails, ask the brain
            // whether remaining steps should be revised given the current state.
            if let lastOutcome = stepMachine.stepOutcomes.last,
               case .failed(let failReason) = lastOutcome.outcome,
               stepMachine.currentStepIndex + 1 < mutablePlan.steps.count {
                let replanResult = await handleMidRunReplanning(
                    step: step, failReason: failReason,
                    command: command, plan: mutablePlan,
                    totalInput: &totalInput, totalOutput: &totalOutput,
                    journal: journal, replyChannel: replyChannel,
                    onStateChange: onStateChange, onMessage: onMessage
                )
                switch replanResult {
                case .continue:
                    break
                case .abort(let runResult):
                    return runResult
                }
            }

            // Advance to next step (skip if already marked as skipped by replanning)
            stepMachine.currentStepIndex += 1
            while stepMachine.currentStepIndex < mutablePlan.steps.count,
                  stepMachine.stepOutcomes.contains(where: { $0.stepId == stepMachine.currentStepIndex && isSkipped($0.outcome) }) {
                stepMachine.currentStepIndex += 1
            }
        }

        // --- All steps completed: run final verification ---
        return await runFinalStepVerification(
            runId: runId, command: command, plan: mutablePlan,
            iteration: iteration,
            anyToolCallsExecuted: anyToolCallsExecuted,
            anyVisualToolCalls: anyVisualToolCalls,
            totalInput: totalInput, totalOutput: totalOutput,
            verificationInputTokens: verificationInputTokens,
            verificationOutputTokens: verificationOutputTokens,
            journal: journal, observer: observer,
            onStateChange: onStateChange,
            agentLoop: agentLoop
        )
    }

    // MARK: - Step-Driven Loop Helpers

    /// Abort a step-driven run due to a critical failure.
    private func abortStepDrivenRun(
        runId: String,
        reason: String,
        iteration: Int,
        totalInput: Int,
        totalOutput: Int,
        verificationInputTokens: Int,
        verificationOutputTokens: Int,
        journal: RunJournal,
        replyChannel: (any ReplyChannel)?,
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        onMessage: @Sendable @escaping (ChatMessage) -> Void
    ) async -> RunResult {
        NSLog("CyclopOne [Orchestrator]: ABORTING plan — %@", reason)
        await journal.append(.fail(reason: reason))
        await journal.close()
        if let rc = replyChannel { await rc.sendText("ABORTED: \(reason)") }
        onMessage(ChatMessage(role: .system, content: reason))
        onStateChange(.error(reason))
        lifecycle.endRun()
        return RunResult(
            runId: runId, success: false, summary: reason,
            iterations: iteration, finalScore: nil,
            totalInputTokens: totalInput, totalOutputTokens: totalOutput,
            verificationInputTokens: verificationInputTokens,
            verificationOutputTokens: verificationOutputTokens
        )
    }

    /// Result of mid-run replanning.
    enum MidRunReplanResult {
        case `continue`
        case abort(RunResult)
    }

    /// Handle mid-run replanning after a non-critical step failure.
    private func handleMidRunReplanning(
        step: PlanStep,
        failReason: String,
        command: String,
        plan: ExecutionPlan,
        totalInput: inout Int,
        totalOutput: inout Int,
        journal: RunJournal,
        replyChannel: (any ReplyChannel)?,
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        onMessage: @Sendable @escaping (ChatMessage) -> Void
    ) async -> MidRunReplanResult {
        let remainingSteps = Array(plan.steps[(stepMachine.currentStepIndex + 1)...])
        let remainingDesc = remainingSteps.map { "Step \($0.id + 1): \($0.title) — \($0.action)" }.joined(separator: "\n")
        let replanPrompt = """
        The agent is executing: "\(command)"
        Step \(step.id + 1) ("\(step.title)") FAILED: \(failReason)

        Remaining steps:
        \(remainingDesc)

        Given the failure, should the remaining steps be adjusted? Reply with EXACTLY one of:
        1. CONTINUE — remaining steps are still valid, proceed as planned
        2. SKIP <step_numbers> — skip specific steps (comma-separated, e.g., "SKIP 4,5")
        3. ABORT — the task cannot be completed due to this failure

        Be concise. Only suggest changes if the failure actually impacts remaining steps.
        """
        do {
            let brainModel = AgentConfig().brainModel
            let replanMessage: APIMessage
            if let lastSS = stepMachine.preActionScreenshot {
                replanMessage = APIMessage.userWithScreenshot(text: replanPrompt, screenshot: lastSS, uiTreeSummary: nil)
            } else {
                replanMessage = APIMessage.userText(replanPrompt)
            }
            let replanResponse = try await ClaudeAPIService.shared.sendMessage(
                messages: [replanMessage],
                systemPrompt: "You are a plan advisor for a desktop automation agent. Assess whether remaining plan steps need adjustment after a step failure. Be conservative — only suggest changes when clearly necessary.",
                tools: [],
                model: brainModel,
                maxTokens: 256
            )
            let replanText = replanResponse.textContent.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            totalInput += replanResponse.inputTokens
            totalOutput += replanResponse.outputTokens

            if replanText.hasPrefix("ABORT") {
                let abortReason = "Brain advised abort after step \(step.id + 1) failure: \(failReason)"
                NSLog("CyclopOne [Orchestrator]: Mid-run replan: ABORT — %@", abortReason)
                await journal.append(.fail(reason: abortReason))
                await journal.close()
                onMessage(ChatMessage(role: .system, content: abortReason))
                onStateChange(.error(abortReason))
                lifecycle.endRun()
                return .abort(RunResult(
                    runId: lifecycle.currentRunId ?? "unknown", success: false, summary: abortReason,
                    iterations: 0, finalScore: nil,
                    totalInputTokens: totalInput, totalOutputTokens: totalOutput
                ))
            } else if replanText.hasPrefix("SKIP") {
                // Parse step numbers to skip
                let skipPart = replanText.replacingOccurrences(of: "SKIP", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                let skipNumbers = skipPart.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                for skipNum in skipNumbers {
                    let skipIdx = skipNum - 1  // Convert 1-indexed to 0-indexed
                    if skipIdx > stepMachine.currentStepIndex && skipIdx < plan.steps.count {
                        stepMachine.stepOutcomes.append((skipIdx, .skipped(reason: "Skipped by mid-run replan after step \(step.id + 1) failure")))
                        NSLog("CyclopOne [Orchestrator]: Mid-run replan: skipping step %d", skipNum)
                    }
                }
                onMessage(ChatMessage(role: .system, content: "Plan adjusted: skipping steps \(skipNumbers.map(String.init).joined(separator: ", "))"))
            } else {
                NSLog("CyclopOne [Orchestrator]: Mid-run replan: CONTINUE (no changes)")
            }
        } catch {
            NSLog("CyclopOne [Orchestrator]: Mid-run replan failed: %@ — continuing as planned", error.localizedDescription)
        }
        return .continue
    }

    /// Run final verification after all steps complete.
    private func runFinalStepVerification(
        runId: String,
        command: String,
        plan: ExecutionPlan,
        iteration: Int,
        anyToolCallsExecuted: Bool,
        anyVisualToolCalls: Bool,
        totalInput: Int,
        totalOutput: Int,
        verificationInputTokens: Int,
        verificationOutputTokens: Int,
        journal: RunJournal,
        observer: (any AgentObserver)?,
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        agentLoop: AgentLoop? = nil
    ) async -> RunResult {
        NSLog("CyclopOne [Orchestrator]: All %d steps completed, running final verification", plan.steps.count)

        let stepSummary = stepMachine.stepOutcomes.map { (id, outcome) in
            "Step \(id + 1): \(stepMachine.describeOutcome(outcome))"
        }.joined(separator: "; ")

        var verificationInputTokens = verificationInputTokens
        var verificationOutputTokens = verificationOutputTokens

        // Final verification using existing VerificationEngine
        let score: Int
        let passed: Bool
        let reason: String
        if !anyToolCallsExecuted {
            score = 100; passed = true; reason = "Text-only run, auto-pass"
        } else if !anyVisualToolCalls {
            score = 100; passed = true; reason = "Non-visual tools only, auto-pass"
        } else {
            let verificationResult = await verificationEngine.verify(
                command: command,
                textContent: stepSummary,
                postScreenshot: stepMachine.preActionScreenshot,
                preScreenshot: nil,
                threshold: runConfig.verificationThreshold
            )
            score = verificationResult.overall
            passed = verificationResult.passed
            reason = verificationResult.reason
        }
        verificationInputTokens += await verificationEngine.lastVerificationInputTokens
        verificationOutputTokens += await verificationEngine.lastVerificationOutputTokens

        NSLog("CyclopOne [Orchestrator]: Step-driven run complete -- score=%d, passed=%d, steps=%d, iterations=%d",
              score, passed, plan.steps.count, iteration)

        // M3: Fire completion observer event
        ObserverNotifier.notifyCompletion(
            observer,
            success: passed,
            summary: "Completed (score: \(score), \(plan.steps.count) steps)",
            score: score,
            iterations: iteration
        )

        await journal.append(.complete(
            summary: "Plan complete (\(plan.steps.count) steps, verification: \(score)). \(stepSummary)",
            finalScore: score
        ))
        await journal.close()

        // Post-run memory recording
        await recordRunCompletion(runId: runId, command: command, passed: passed, score: score, reason: reason, iteration: iteration, agentLoop: agentLoop)

        onStateChange(.done)
        lifecycle.endRun()
        let result = RunResult(
            runId: runId, success: passed, summary: "Completed (score: \(score), \(plan.steps.count) steps)",
            iterations: iteration, finalScore: score,
            totalInputTokens: totalInput, totalOutputTokens: totalOutput,
            verificationInputTokens: verificationInputTokens,
            verificationOutputTokens: verificationOutputTokens
        )
        updateClassifierContext(command: command, result: result)
        return result
    }
}
