# TODO
for backup repository config see https://velero.io/docs/v1.16/backup-repository-configuration/

need to specify --backup-repository-configmap in configuration.extraArgs
and add config map in configMaps

config map needs to look like:

```
apiVersion: v1
kind: ConfigMap
metadata:
  name: backup-repository-config
  namespace: velero
data:
  "kopia": |
    {
      "cacheLimitMB": 2048    
      "enableCompression": true 
    }
```
