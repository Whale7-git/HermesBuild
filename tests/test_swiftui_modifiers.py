#!/usr/bin/env python3
"""Positive/negative regression fixtures for the Linux-only SwiftUI guard."""

import unittest

from check_swiftui_modifiers import mask_non_code, offenses, ui_interaction_offenses


class ModifierGuardTests(unittest.TestCase):
    def test_if_else_then_modifier_fails(self):
        code = '''@ViewBuilder
var v: some View {
    if big {
        Label("Read", systemImage: "text.page")
    } else {
        Image(systemName: "text.page")
    }
        .contentShape(Rectangle())
}
'''
        self.assertEqual([line for line, _ in offenses(code)], [8])

    def test_each_control_block_fails(self):
        for statement in ('if flag', 'for item in items', 'switch state',
                          'guard flag else', 'while flag'):
            with self.subTest(statement=statement):
                code = f'{statement} {{\n    view\n}}\n    .contentShape(Rectangle())\n'
                self.assertEqual(len(offenses(code)), 1)

    def test_group_and_stacks_are_legal(self):
        for view in ('Group', 'HStack', 'VStack'):
            with self.subTest(view=view):
                code = f'''{view} {{
    if big {{
        Text("a")
    }} else {{
        Text("b")
    }}
}}
    .contentShape(Rectangle())
'''
                self.assertEqual(offenses(code), [])

    def test_lower_or_equal_modifier_indentation_does_not_trigger(self):
        self.assertEqual(offenses('if ok {\n    v\n}\n.contentShape(Rectangle())\n'), [])

    def test_comments_and_strings_do_not_corrupt_brace_stack(self):
        code = '''let unused = "{ and }"
/* nested { /* } */ } */
Group {
    if x {
        Text("hello }")
    }
}
    .contentShape(Rectangle())
'''
        self.assertEqual(offenses(code), [])
        self.assertEqual(mask_non_code('"{ { }"').count('{'), 0)

    def test_bare_icon_label_is_detected_and_sized_label_is_safe(self):
        tiny = '''
Button { dismiss() } label: {
    Image(systemName: "xmark")
}
'''
        self.assertEqual(len(ui_interaction_offenses(tiny, "Example.swift")), 1)
        for modifier in (
            '.frame(minWidth: 44, minHeight: 44)',
            '.frame(width: 44, height: 44)',
            '.padding(16)',
            '.contentShape(Rectangle())',
        ):
            with self.subTest(modifier=modifier):
                large = tiny.replace('Image(systemName: "xmark")',
                                     f'Image(systemName: "xmark")\n        {modifier}')
                self.assertEqual(ui_interaction_offenses(large, "Example.swift"), [])

    def test_unprotected_animation_fails_even_with_unrelated_reduce_motion(self):
        source = '''@Environment(\\.accessibilityReduceMotion) var reduceMotion
func reveal() {
    withAnimation(.easeOut(duration: 0.2)) { shown = true }
}
'''
        self.assertEqual(len(ui_interaction_offenses(source, "NewView.swift")), 1)
        protected = source.replace('withAnimation(.easeOut',
                                   'withAnimation(reduceMotion ? nil : .easeOut')
        self.assertEqual(ui_interaction_offenses(protected, "NewView.swift"), [])

    def test_legacy_findings_are_scoped_to_exact_file_and_call(self):
        site = 'withAnimation(.easeOut(duration: 0.18)) { active = true }'
        self.assertEqual(ui_interaction_offenses(site, "ChatMessageReader.swift"), [])
        self.assertEqual(len(ui_interaction_offenses(site, "NewView.swift")), 1)
        other = 'withAnimation(.easeOut(duration: 0.31)) { active = true }'
        self.assertEqual(len(ui_interaction_offenses(other, "ChatMessageReader.swift")), 1)

    def test_hosted_scroll_risk_not_silently_accepted_for_new_view(self):
        fragment = '''let host = UIHostingController(rootView: content())
scrollView.addSubview(host.view)
host.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor)
'''
        self.assertEqual(len(ui_interaction_offenses(fragment, "NewReader.swift")), 1)
        self.assertEqual(ui_interaction_offenses(fragment, "ChatMessageReader.swift"), [])
        with_size = fragment + 'host.view.heightAnchor.constraint(equalToConstant: 100)\n'
        self.assertEqual(ui_interaction_offenses(with_size, "NewReader.swift"), [])



if __name__ == '__main__':
    unittest.main()
