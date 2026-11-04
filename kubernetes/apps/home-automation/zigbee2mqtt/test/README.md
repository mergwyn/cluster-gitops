### Notes

```
export NS=home-assistant
kubectl apply -f z2m-config-test.yaml
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/z2m-config-test --timeout=120s
kubectl -n "$NS" logs z2m-config-test
kubectl -n "$NS" delete pod z2m-config-test
```
