Need to make sure secret is created externally before bootstrap

'''
kubectl create secret generic bitwarden-access-token -n bitwarden --from-literal=token="<Auth-Token-Here>"
'''
