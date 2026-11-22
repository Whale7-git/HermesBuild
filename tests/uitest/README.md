# Hermes iOS UI test Gateway

`mock_gateway.py` 是供 UI 测试使用的本地合成 Gateway。它只监听 loopback（`127.0.0.1`），不连接真实实例，不使用真实账号或用户数据。

## 运行

```sh
python3 tests/uitest/mock_gateway.py --port 8765
python3 -m unittest discover -s tests/uitest -p 'test_*.py' -v
```

## 测试数据与安全边界

- 固定响应数据保存在 `tests/uitest/fixtures/`；服务端路由、状态和故障注入实现位于 `mock_gateway.py`，对应契约测试位于 `test_mock_gateway.py`。修改路由或响应时同步更新测试，不要维护第二份路由清单。
- `/__control` 路由仅用于测试控制、重置和检查请求记录。请求日志只记录认证信息是否存在及其方案，不保存密钥、Cookie 值或消息正文。
- 未知路由返回 `501 MOCK_UNKNOWN_ROUTE`，并记录下来；不要为了让测试通过而静默模拟未实现的生产接口。
- 测试中的图片为内嵌合成 PNG，不会写入真实用户文件。

## 范围

Python 测试验证 mock Gateway 的 HTTP 契约和故障注入，不验证 iOS 真实手势、排版或设备行为。模拟器 UI 回归是独立的手动工作流；真机结果必须单独记录。
