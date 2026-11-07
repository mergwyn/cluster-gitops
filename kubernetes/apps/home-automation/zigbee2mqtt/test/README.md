### Notes

## Test 1
```
export NS=home-assistant
kubectl apply -f z2m-config-test.yaml
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/z2m-config-test --timeout=120s
kubectl -n "$NS" logs z2m-config-test
kubectl -n "$NS" delete pod z2m-config-test
```

## Test 2 - split config
```
#!/usr/bin/env bash
set -euo pipefail

sed -i 's/node --input-type=module \/tmp\/t.mjs/node \/tmp\/t.mjs/' z2m-split-test.yaml
grep -n 'node /tmp/t.mjs' z2m-split-test.yaml   # expect 3 matches

NS=home-assistant
kubectl -n "$NS" delete pod z2m-split-test --ignore-not-found
kubectl apply -f z2m-split-test.yaml
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/z2m-split-test --timeout=120s
kubectl -n "$NS" logs z2m-split-test
kubectl -n "$NS" delete pod z2m-split-test
```

## Test 3
Scenario is to test:

initContainer clones repo containing devices and groups.yaml
Main container starts with ZIGBEE2MQTT_CONFIG_DEVICES=devices.yaml and reads the config restored from git.

```
NS=home-assistant
kubectl -n "$NS" delete pod z2m-fresh-test --ignore-not-found
kubectl apply -f z2m-fresh-test.yaml
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/z2m-fresh-test --timeout=120s
kubectl -n "$NS" logs z2m-fresh-test
kubectl -n "$NS" delete pod z2m-fresh-test
```
