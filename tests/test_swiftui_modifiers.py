#!/usr/bin/env python3
"""Positive/negative regression fixtures for the Linux-only SwiftUI guard."""

import unittest

from check_swiftui_modifiers import mask_non_code, offenses


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


if __name__ == '__main__':
    unittest.main()
