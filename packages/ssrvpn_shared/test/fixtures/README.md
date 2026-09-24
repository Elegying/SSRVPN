# Proxy option compatibility fixtures

`proxy_option_cases.json` contains 143 synthetic cases checked independently
against the shipped Windows core using `mihomo.exe -t` on 2026-09-24.
`accepted` means that the application should retain the node. It is not proof
of a successful remote handshake.

The raw core verdict supplies the expectation except for application-supported
VMess defaults, `alter-id`, and `socks`, which require canonical runtime output.
`expect_fields` records that output. The Windows integration test loads every
generated configuration using the real packaged core, with a healthy sibling
that must survive rejection of a malformed node.

The decoder and common option layouts were compared at these exact revisions:

- Windows: MetaCubeX/mihomo `5184081ac327394d9e15fa5d5f9f4a61e723fd94`
- Android: zeyugao/mihomo `7031b7569831677a8d89ad8a8a3347db116ba1a8`
- macOS: MetaCubeX/mihomo `e26714a181ac0e2fa803453c0a8e9a9ce94e31cb`

Relevant upstream paths: `common/structure/structure.go`, `adapter/outbound`,
`common/utils/mbps.go`, `transport/shadowsocks/core/cipher.go`, and
`transport/vless/encryption`. Update both the decoder schema and independently
verified fixtures when changing a core pin. Unknown optional keys are retained;
the schema covers the shared option layout, not every platform-specific extension.
