TODO: work how to add the `routed-gatway` label to those namespaces that require gateway support:
```
routed_namespace=downloaders
kubectl create namespace ${routed_namespace} || true
kubectl label namespace ${routed_namespace} routed-gateway=true
```
