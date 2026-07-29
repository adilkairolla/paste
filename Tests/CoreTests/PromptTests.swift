import Foundation
import PasteDeckCore

private func names(_ body: String) -> [String] {
    PromptTemplate(body: body).variables.map(\.name)
}

func runPromptTests() {
    suite("PromptTemplate") {
        test("finds slots in order of first appearance, deduplicated") {
            expectEqual(names("{{topic}} then {{tone}} then {{topic}} again"), ["topic", "tone"])
        }

        test("normalises whitespace and case so one slot means one field") {
            expectEqual(names("{{ Topic }} and {{topic}} and {{TOPIC}}"), ["topic"])
            expectEqual(names("{{target   audience}}"), ["target audience"])
        }

        test("leaves malformed braces exactly as written") {
            // Nothing here is a slot, so nothing may disappear on paste.
            for body in ["{{}}", "{{ }}", "{{2 + 2}}", "{{a/b}}", "{{unclosed", "plain {braces}"] {
                expectEqual(names(body), [], "parsed \(body)")
                expectEqual(PromptTemplate(body: body).rendered(with: [:]), body, "rendered \(body)")
            }
        }

        test("recognises the built-in slots and separates them from typed ones") {
            let template = PromptTemplate(body: "{{clipboard}} {{stack}} {{audience}}")
            expectEqual(template.variables.count, 3)
            expectEqual(template.variables.filter(\.isBuiltIn).map(\.name), ["clipboard", "stack"])
            expectEqual(template.userVariables.map(\.name), ["audience"])
            expectEqual(template.variables.first?.builtIn, .clipboard)
        }

        test("substitutes every occurrence, matching names case-insensitively") {
            let template = PromptTemplate(body: "Dear {{Name}}, hello {{name}}.")
            expectEqual(template.rendered(with: ["NAME": "Ada"]), "Dear Ada, hello Ada.")
        }

        test("collapses slots with no value rather than pasting the braces") {
            let template = PromptTemplate(body: "a {{missing}} b")
            expectEqual(template.rendered(with: [:]), "a  b")
        }

        test("preserves surrounding text and newlines untouched") {
            let template = PromptTemplate(body: "line one\n\n{{body}}\n\nline three")
            expectEqual(
                template.rendered(with: ["body": "middle"]),
                "line one\n\nmiddle\n\nline three"
            )
        }

        test("a body with no slots renders to itself") {
            let template = PromptTemplate(body: "nothing to fill in here")
            expect(!template.hasVariables)
            expectEqual(template.rendered(with: ["unused": "x"]), "nothing to fill in here")
        }

        test("capitalises slot names for display without altering the key") {
            let variable = try require(PromptTemplate(body: "{{target audience}}").variables.first)
            expectEqual(variable.displayName, "Target audience")
            expectEqual(variable.name, "target audience")
        }
    }

    suite("StackComposer") {
        let error = StackComposer.Entry(kind: .text, sourceAppName: "Terminal", text: "boom")
        let code = StackComposer.Entry(kind: .code, sourceAppName: "Ghostty", text: "let x = 1", language: "swift")

        test("one entry composes to its own text, with no heading") {
            expectEqual(StackComposer.compose([code]), "let x = 1")
        }

        test("no entries compose to nothing") {
            expectEqual(StackComposer.compose([]), "")
        }

        test("labels each part by kind and source app") {
            expectEqual(
                StackComposer.compose([error, code]),
                """
                ### Text · Terminal
                boom

                ### Code · Ghostty
                ```swift
                let x = 1
                ```
                """
            )
        }

        test("omits the source when the app is unknown") {
            let anonymous = StackComposer.Entry(kind: .text, text: "hi")
            expect(StackComposer.compose([anonymous, error]).contains("### Text\nhi"))
        }

        test("grows the fence past backticks in the content") {
            let nested = StackComposer.Entry(
                kind: .code,
                sourceAppName: "Notes",
                text: "```\ninner\n```",
                language: nil
            )
            let composed = StackComposer.compose([nested, error])
            expect(composed.contains("````\n```\ninner\n```\n````"), "fence did not grow: \(composed)")
        }

        test("only fences code — plain text stays plain") {
            let composed = StackComposer.compose([error, error])
            expect(!composed.contains("```"), "plain text was fenced")
        }
    }

    suite("Prompt library") {
        test("stores a prompt and reads its body back verbatim") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let body = "Explain {{topic}} to {{audience}}."
                let prompt = try store.createPrompt(title: "Explain", body: body)

                expectEqual(prompt.kind, .prompt)
                expectEqual(prompt.title, "Explain")
                expectEqual(try store.promptBody(itemID: prompt.id), body)
                expectEqual(prompt.metadata.promptVariables ?? [], ["topic", "audience"])
            }
        }

        test("titles itself from the first non-empty line when none is given") {
            expectEqual(
                PromptLibrary.displayTitle(title: "  ", body: "\n\n  Summarise this  \nand that"),
                "Summarise this"
            )
            expectEqual(PromptLibrary.displayTitle(title: "", body: "   "), "Untitled prompt")
        }

        test("a prompt body does not collide with identical copied text") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let shared = "the very same words"

                let snapshot = PasteboardSnapshot(
                    items: [.init(representations: [.init(uti: UTI.plainText, data: Data(shared.utf8))])],
                    sourceBundleID: "com.apple.Safari",
                    sourceAppName: "Safari"
                )
                _ = try store.insert(ClipClassifier().classify(snapshot)!)
                _ = try store.createPrompt(title: "A prompt", body: shared)

                expectEqual(try store.count(.prompts), 1)
                expectEqual(try store.count(.all), 1)
            }
        }

        test("editing keeps the id, categories and payload count") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let prompt = try store.createPrompt(title: "Before", body: "old {{a}}")
                let category = try store.createCategory(name: "Writing")
                try store.addItem(prompt.id, toCategory: category.id)

                try store.updatePrompt(itemID: prompt.id, title: "After", body: "new {{b}} {{c}}")

                let reloaded = try require(try store.item(id: prompt.id))
                expectEqual(reloaded.id, prompt.id)
                expectEqual(reloaded.title, "After")
                expectEqual(reloaded.categoryIDs, [category.id])
                expectEqual(try store.promptBody(itemID: prompt.id), "new {{b}} {{c}}")
                expectEqual(reloaded.metadata.promptVariables ?? [], ["b", "c"])
                // The old text must be gone, not merely outranked.
                expectEqual(try store.payloads(itemID: prompt.id).count, 1)
            }
        }

        test("prompts stay out of history views but fill their own tab") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let snapshot = PasteboardSnapshot(
                    items: [.init(representations: [.init(uti: UTI.plainText, data: Data("copied".utf8))])],
                    sourceAppName: "Safari"
                )
                _ = try store.insert(ClipClassifier().classify(snapshot)!)
                let prompt = try store.createPrompt(title: "Template", body: "body")
                try store.setPinned(true, itemID: prompt.id)

                expectEqual(try store.items(ClipQuery(filter: .all)).map(\.kind), [.text])
                expectEqual(try store.items(ClipQuery(filter: .prompts)).map(\.kind), [.prompt])
                // Pinning a prompt must not smuggle it into the Pinned tab.
                expectEqual(try store.items(ClipQuery(filter: .pinned)).count, 0)
                expectEqual(try store.count(.all), 1)
                expectEqual(try store.count(.pinned), 0)
                expectEqual(try store.count(.prompts), 1)
            }
        }

        test("prompts survive every retention limit") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let ancient = Date(timeIntervalSinceNow: -400 * 86_400)
                _ = try store.createPrompt(title: "Keep me", body: "forever", now: ancient)

                for index in 0..<20 {
                    let snapshot = PasteboardSnapshot(
                        items: [.init(representations: [.init(uti: UTI.plainText, data: Data("junk \(index)".utf8))])],
                        sourceAppName: "Safari",
                        capturedAt: ancient
                    )
                    _ = try store.insert(ClipClassifier().classify(snapshot)!)
                }

                let report = try Retention.prune(
                    store: store,
                    policy: RetentionPolicy(maxItems: 1, maxAgeDays: 1, maxBytes: 1)
                )

                expect(report.totalDeleted > 0, "nothing was pruned, so the test proves nothing")
                expectEqual(try store.count(.prompts), 1)
            }
        }

        test("starter prompts are seeded once and stay deleted") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let defaults = try require(UserDefaults(suiteName: "pastedeck-tests-\(UUID().uuidString)"))
                let preferences = Preferences(defaults: defaults)

                store.seedStarterPrompts(preferences: preferences)
                expectEqual(try store.count(.prompts), PromptLibrary.starters.count)

                let all = try store.items(ClipQuery(filter: .prompts))
                try store.delete(itemIDs: all.map(\.id))
                store.seedStarterPrompts(preferences: preferences)
                expectEqual(try store.count(.prompts), 0)
            }
        }

        test("editing a prompt into a copy of another is refused") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                _ = try store.createPrompt(title: "One", body: "same body")
                let second = try store.createPrompt(title: "Two", body: "different")

                do {
                    try store.updatePrompt(itemID: second.id, title: "One", body: "same body")
                    fail("expected a duplicate error")
                } catch ClipEditError.duplicate {
                    // The original must survive untouched.
                    expectEqual(try store.promptBody(itemID: second.id), "different")
                }
            }
        }

        test("every starter prompt parses to the slots it advertises") {
            for starter in PromptLibrary.starters {
                let template = PromptTemplate(body: starter.body)
                expect(template.hasVariables, "\(starter.title) has no slots")
                for variable in template.variables where variable.isBuiltIn {
                    expect(
                        PromptTemplate.BuiltIn(rawValue: variable.name) != nil,
                        "\(starter.title) claims unknown built-in \(variable.name)"
                    )
                }
            }
        }
    }
}
