# AppMana mocked script tests

Same convention as `forks-calico-windows-ipv6/hack/appmana/tests/`: exercise
the shipped scripts against mocked external behavior, no cluster and no HNS
required. The calico fork mocks external binaries on `PATH` for its bash
scripts; here the PowerShell scripts take injectable query scriptblocks, and
the tests inject mocks that simulate HNS behavior — including the failure
modes observed in production.

Run locally (PowerShell Core is fine, no Windows needed):

```sh
pwsh -NoProfile -File hack/appmana/tests/wait-hns.tests.ps1
```

CI runs the tests in the build workflow before images are built, so a
behavioral regression fails the build rather than the fleet.

## wait-hns.tests.ps1

Covers `hostprocess/calico/kube-proxy/wait-hns.psm1`
(`Wait-HnsNetworkReady`), which gates kube-proxy startup:

1. network already present: returns promptly
2. network appears after a few polls: returns after retrying
3. **query call blocks forever**: must still complete once a later query
   succeeds. This is the 2026-07-07 production regression: a
   `Get-HnsNetwork` issued while the HNS service restarts (node reboot,
   kubelet swap) never returns, and an unguarded in-process loop therefore
   froze kube-proxy startup on all three Windows nodes for an hour. The wait
   must bound every query with a timeout and retry in a fresh process.
