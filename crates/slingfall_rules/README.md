# slingfall_rules

The game rules on top of `rapier2d`: the world built from a `Level`, the slingshot (pull clamp and
launch), damage from contact-force events, the end-of-shot calm rule, out-of-bounds removal,
scoring and the win condition (`docs/DESIGN.md` D3, D5-D7). Everything goes through `rapier2d`'s
public API; a missing accessor is an escalation. Modules `world`, `sling`, `damage`, `calm`,
`score` are stubs until lot G3. Test: `snforge test -p slingfall_rules`.
