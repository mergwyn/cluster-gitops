# NOTES
For backup repository config see https://velero.io/docs/v1.16/backup-repository-configuration/

Specify `--backup-repository-configmap=backup-repository-config` in `configuration.extraArgs` and add config map in `configMaps`

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
