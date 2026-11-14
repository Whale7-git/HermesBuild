"""Read-only probe of DEPLOYED route functions with explicitly synthetic data.
Not an authenticated HTTP test; never loads production messages or changes service state.
Run: ssh -o BatchMode=yes user@build-host \
 'docker exec -i your-webui-container python - /app/api/routes.py' < tests/discovery/deployed_contract_probe.py
"""
import ast
from pathlib import Path
import re
import sys
import types
from urllib.parse import parse_qs, urlparse

source = Path(sys.argv[1]).read_text()
tree = ast.parse(source)
names = {'_session_search_message_text', '_session_search_preview', '_handle_sessions_search'}
functions = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names]
assert len(functions) == 3
profiles = types.ModuleType('api.profiles')
profiles.get_active_profile_name = lambda: 'fixture-profile'
api = types.ModuleType('api')
api.profiles = profiles
sys.modules['api'] = api
sys.modules['api.profiles'] = profiles
rows = [{'session_id': 'synthetic-only', 'profile': 'fixture-profile', 'title': 'unrelated title'}]
messages = [{'content': 'unrelated'} for _ in range(6)] + [{'content': 'deep_body_marker'}]
namespace = dict(parse_qs=parse_qs, re=re,
                 all_sessions=lambda: rows,
                 _all_profiles_enabled=lambda parsed: False,
                 _profiles_match=lambda a, b: a == b,
                 load_settings=lambda: {'api_redact_enabled': False},
                 _redact_text=lambda text, **kwargs: text,
                 _redact_sidebar_title_fields=lambda item, enabled: None,
                 get_session_for_scan=lambda sid: types.SimpleNamespace(messages=messages),
                 j=lambda handler, payload: payload)
exec(compile(ast.Module(body=functions, type_ignores=[]), '<deployed-search-functions>', 'exec'), namespace)
search = namespace['_handle_sessions_search']
short = search(None, urlparse('/api/sessions/search?q=deep_body_marker&content=1&depth=5'))
full = search(None, urlparse('/api/sessions/search?q=deep_body_marker&content=1&depth=0'))
assert short['count'] == 0
assert full['count'] == 1 and full['sessions'][0]['match_type'] == 'content'
assert 'deep_body_marker' in full['sessions'][0]['match_preview']
print('PASS: deployed depth=0 finds synthetic message 7; depth=5 does not; body preview returned')

page_assignment = [node for node in ast.walk(tree)
                   if isinstance(node, ast.Assign)
                   and isinstance(node.value, ast.BinOp)
                   and isinstance(node.value.right, ast.Subscript)
                   and isinstance(node.value.right.value, ast.Name)
                   and node.value.right.value.id == 'archived_rows_for_page']
assert len(page_assignment) == 1
scope = dict(visible_rows_for_page=['active-1', 'active-2'],
             archived_rows_for_page=['archive-1', 'archive-2', 'archive-3'],
             normalized_archived_offset=2, normalized_archived_limit=1)
exec(compile(ast.Module(body=page_assignment, type_ignores=[]), '<deployed-archive-page>', 'exec'), scope)
assert scope['scoped'] == ['active-1', 'active-2', 'archive-3']
route_start = source.index('    if parsed.path == "/api/sessions":')
route_end = source.index('    if parsed.path == "/api/projects":', route_start)
route = source[route_start:route_end]
params = re.findall(r'_query_positive_int\(parsed, "([^"]+)"', route)
assert set(params) == {'archived_limit', 'archived_offset'}, params
print('PASS: deployed archive slice honors offset/limit, repeats all active rows; no active-list page parameters')
