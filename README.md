# disto-deploy

delete cluster:
gcloud container clusters delete disto --zone us-west1

get ip address of frontend:
kubectl get svc frontend-service -o=jsonpath='{.status.loadBalancer.ingress[0].ip}'
