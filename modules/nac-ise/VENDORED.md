# Vendored nac-ise

Copy of [netascode/nac-ise/ise](https://registry.terraform.io/modules/netascode/nac-ise/ise/latest)
v1.1.0 (git tag `v1.1.0`, commit 29aa714474ab0124c81435ac6adb3872653153b7), without `examples/`
and CI files.

One change, in `versions.tf`: the `netascode/utils` constraint is relaxed from `2.0.0` to
`>= 2.0.0, < 3.0.0`. Upstream pins exactly 2.0.0, while nac-iosxe 1.0.0 (used for FUSION-1 in the
same root module) needs `>= 2.0.2, < 3.0.0`, so the two modules cannot share one root otherwise.

To update: copy the new upstream release over this directory and re-apply the change, or drop the
vendored copy once upstream relaxes the constraint.
