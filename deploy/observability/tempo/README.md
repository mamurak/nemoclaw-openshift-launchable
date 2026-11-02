# Tempo TempoStack Helm Chart

This directory contains the Helm chart for deploying a TempoStack instance that uses a shared S3-compatible storage backend (RustFS). This chart is designed to work with the Tempo Operator and depends on the shared RustFS instance deployed by the `object-storage` chart.

## Overview

This configuration includes:
- **TempoStack Instance**: Multitenant Tempo configuration
- **Shared S3 Storage**: Uses the shared RustFS instance for trace storage
- **Storage Secrets**: Credentials and connection details for the shared RustFS instance
- **RBAC**: Cluster roles for trace access

## Prerequisites

1. **Tempo Operator**: Must be installed first using the tempo-operator Helm chart:
   ```bash
   helm install tempo-operator ../tempo-operator/
   ```

2. **Shared object storage**: The shared RustFS instance must be deployed first:
   ```bash
   helm upgrade --install object-storage ../object-storage/ -n observability-hub
   ```

3. **Namespace**: Ensure the `observability-hub` namespace exists:
   ```bash
   kubectl create namespace observability-hub
   ```

## Deployment

Deploy the TempoStack configuration using Helm:

```bash
helm install tempo-stack .
```

This will create:
- TempoStack instance configured for multitenancy with Gateway access
- Storage secrets that reference the shared RustFS instance
- Required RBAC permissions

## Configuration Details

### Shared S3 Storage (RustFS)
- **Deployment**: Uses the shared `observability-object-storage` instance
- **Service**: `observability-object-storage` ClusterIP service on port 9000 (console on 9001)
- **Credentials**: `s3.accessKeyId` / `s3.accessKeySecret` in `values.yaml` (must match `../object-storage/values.yaml`)
  - User: `admin`
  - Password: `observability123`
  - Bucket: `tempo` (created by the object-storage chart's bucket-init Job)

### TempoStack Configuration
- **Name**: `tempostack`
- **Storage**: Uses shared RustFS storage (no local PVC)
- **Resources**: 10Gi memory, 5000m CPU limits
- **Multitenancy**: Enabled with OpenShift mode
- **Tenant**: `dev` tenant pre-configured
- **UI Access**: Gateway enabled, accessible via OpenShift Console (Observe -> Traces)

### RBAC
- **ClusterRole**: `tempostack-traces-reader` for trace access
- **Binding**: Allows all authenticated users to read traces

## Accessing Tempo

After deployment, access traces via the **OpenShift Console**:

1. Navigate to **Observe -> Traces** in the OpenShift console
2. Ensure the **COO UIPlugin** is installed (see observability documentation)

Alternative: Check for gateway services:
```bash
oc get services -n observability-hub -l app.kubernetes.io/component=gateway
```

**Note**: The legacy Jaeger Query UI route has been disabled in favor of the modern Gateway + COO UIPlugin approach.

## Security Considerations

⚠️ **Important**: The default object storage credentials are for development/testing only. For production deployments:

1. Change the credentials in the shared object-storage chart (`../object-storage/values.yaml`)
2. Update `s3.accessKeyId` / `s3.accessKeySecret` in this chart's `values.yaml`
3. Consider using external S3-compatible storage (e.g. ODF / AWS S3) by pointing `s3.endpoint` at it

## Customization

### Changing Storage Size
Edit the shared object-storage chart (`../object-storage/values.yaml`) to change the storage size:
```yaml
storage:
  persistence:
    size: 20Gi  # Change as needed
```

### Adding More Tenants
Edit `tempo-multitenant.yaml` to add additional tenants:
```yaml
tenants:
  mode: openshift
  authentication:
    - tenantName: dev
      tenantId: "1610b0c3-c509-4592-a256-a1871353dbfa"
    - tenantName: prod
      tenantId: "2610b0c3-c509-4592-a256-a1871353dbfb"
```

### Resource Limits
Adjust resources in `tempo-multitenant.yaml`:
```yaml
resources:
  total:
    limits:
      memory: 20Gi  # Increase for higher throughput
      cpu: 8000m
```

## Troubleshooting

### Shared Object Storage Not Available
Check if the shared RustFS instance is running:
```bash
kubectl get pods -n observability-hub | grep observability-object-storage
kubectl get pvc -n observability-hub | grep observability-object-storage
```

### TempoStack Not Ready
Check operator logs:
```bash
kubectl logs -n openshift-tempo-operator deployment/tempo-operator-controller
```

Check TempoStack status:
```bash
kubectl get tempostack tempostack -n observability-hub -o yaml
```

### Storage Secret Issues
Verify the Tempo S3 secret is properly configured:
```bash
kubectl get secret tempo-s3-credentials -n observability-hub -o yaml
```

## Integration with Applications

To send traces to this Tempo instance, configure your applications to send traces to the gateway endpoint. The operator will create the necessary services and routes.

Example OpenTelemetry configuration:
```yaml
exporters:
  otlp:
    endpoint: "http://tempostack-gateway.observability-hub.svc.cluster.local:8080"