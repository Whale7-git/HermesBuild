"""Wiring checks only; these do not replace SwiftUI/device UI acceptance."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
PANE = (ROOT / 'Sources/HermesShell/SessionDrawer.swift').read_text()
VIEW_FILE = ROOT / 'Sources/HermesShell/SessionSearchView.swift'
VIEW = VIEW_FILE.read_text() if VIEW_FILE.exists() else ''

class DiscoveryWiring(unittest.TestCase):
    def test_search_is_server_backed_not_local_title_filter(self):
        self.assertIn('SessionSearchView(', PANE)
        self.assertNotIn('localizedCaseInsensitiveContains', PANE)
        self.assertIn('app.api.discoveryService', PANE)

    def test_archive_has_real_load_more_and_explicit_ordinary_list_limit(self):
        self.assertIn('SessionArchiveView(', PANE)
        self.assertIn('普通列表暂不支持服务端分页', PANE)
        self.assertIn('model.loadMore(service: service)', VIEW)
        self.assertIn('加载更多归档', VIEW)

    def test_search_explains_no_message_jump_and_shows_server_excerpt(self):
        self.assertIn('暂不定位到命中消息', VIEW)
        self.assertIn('hit.preview', VIEW)
        self.assertIn('hit.matchType', VIEW)

    def test_scope_gates_visible_results_and_disappearance_cancels(self):
        self.assertIn('model.scope == scope', VIEW)
        self.assertIn('.onDisappear { model.cancel() }', VIEW)
        self.assertIn('activeChangeToken', PANE)

    def test_loading_error_empty_and_retry_are_distinct(self):
        for token in ['model.loading', 'model.errorText', 'model.hits.isEmpty', '重试搜索', '没有找到匹配会话']:
            self.assertIn(token, VIEW)

if __name__ == '__main__':
    unittest.main(verbosity=2)
