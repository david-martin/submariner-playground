# submariner-playground

## Prerequisites

Install [subctl](https://submariner.io/operations/deployment/subctl/)

## Cluster & Submariner setup

Set up 2 local kind clusters & install submariner.

```bash
make local-setup
```

## Example 1: Simple nginx export from cluster 2 to cluster 1

*Demo Video*

TODO

*Architecture*

TODO

Deploy an nginx instance to cluster 2

```bash
kubectl --kubeconfig ./tmp/kubeconfigs/submariner-cluster-2.kubeconfig create deployment nginx --image=nginx -n default
kubectl --kubeconfig ./tmp/kubeconfigs/submariner-cluster-2.kubeconfig expose deployment nginx --port=80 -n default
```

Export the nginx service from cluster 2

```bash
subctl export service --kubeconfig ./tmp/kubeconfigs/submariner-cluster-2.kubeconfig --namespace default nginx
```

Verify the service hostname resolve and is routable from cluster 1

```bash
kubectl --kubeconfig ./tmp/kubeconfigs/submariner-cluster-1.kubeconfig -n default run tmp-shell --rm -i --tty --image quay.io/submariner/nettest \
-- /bin/bash
curl -I nginx.default.svc.clusterset.local
```

The response should look something like this:

```txt
HTTP/1.1 200 OK
Server: nginx/1.25.0
Date: Fri, 09 Jun 2023 09:05:58 GMT
Content-Type: text/html
Content-Length: 615
Last-Modified: Tue, 23 May 2023 15:08:20 GMT
Connection: keep-alive
ETag: "646cd6e4-267"
Accept-Ranges: bytes
```

To see the ServiceExport resource, run the following:

```bash
kubectl --kubeconfig ./tmp/kubeconfigs/submariner-cluster-2.kubeconfig get serviceexport nginx -o yaml
```

It should look something like this:

```yaml
apiVersion: multicluster.x-k8s.io/v1alpha1
kind: ServiceExport
metadata:
  creationTimestamp: "2023-06-09T09:05:26Z"
  generation: 1
  name: nginx
  namespace: default
  resourceVersion: "900"
  uid: 847c3315-2fed-4d5b-8d44-27a2fdd7c7cc
status:
  conditions:
  - lastTransitionTime: "2023-06-09T09:05:26Z"
    message: ""
    reason: ""
    status: "True"
    type: Valid
  - lastTransitionTime: "2023-06-09T09:05:26Z"
    message: Service was successfully exported to the broker
    reason: ""
    status: "True"
    type: Synced
```

To see the ServiceImport resource, run the following:

```bash
kubectl --kubeconfig ./tmp/kubeconfigs/submariner-cluster-1.kubeconfig get serviceimport nginx -o yaml
```

It should look something like this:

```yaml
apiVersion: multicluster.x-k8s.io/v1alpha1
kind: ServiceImport
metadata:
  creationTimestamp: "2023-06-09T09:05:26Z"
  generation: 2
  name: nginx
  namespace: default
  resourceVersion: "971"
  uid: 0bfbd853-a101-4002-92b2-49b8f19554d9
spec:
  ports:
  - port: 80
    protocol: TCP
  type: ClusterSetIP
status:
  clusters:
  - cluster: submariner-cluster-2
```
