local k = import 'ksonnet/ksonnet.beta.3/k.libsonnet';
local service = k.core.v1.service;
local deployment = k.apps.v1beta2.deployment;
local container = deployment.mixin.spec.template.spec.containersType;
local volume = deployment.mixin.spec.template.spec.volumesType;
local configmap = k.core.v1.configMap;
local containerPort = container.portsType;
local containerVolumeMount = container.volumeMountsType;
local tmpVolumeName = 'volume-directive-shadow';
local tlsVolumeName = 'kube-state-metrics-tls';

{
  prometheusAdapter+:: {
    local tlsVolumeName = 'prometheus-adapter-tls',

    local prometheusAdapterPrometheusConfig = 'prometheus-adapter-prometheus-config',
    local prometheusAdapterPrometheusConfigPath = '/etc/prometheus-config',

    local servingCertsCABundle = 'serving-certs-ca-bundle',
    local servingCertsCABundleDirectory = 'ssl/certs',
    local servingCertsCABundleFileName = 'service-ca.crt',
    local servingCertsCABundleMountPath = '/etc/%s' % servingCertsCABundleDirectory,

    clusterRoleAggregatedMetricsReader+:
      {
        metadata+: {
          labels+: {
            'rbac.authorization.k8s.io/aggregate-to-cluster-reader': 'true',
          },
        },
      },

    apiService+:
      {
        metadata+: {
          annotations+: {
            'service.alpha.openshift.io/inject-cabundle': 'true',
          },
        },
        spec+: {
          insecureSkipTLSVerify: false,
        },
      },

    service+:
      {
        metadata+: {
          annotations+: {
            'service.beta.openshift.io/serving-cert-secret-name': tlsVolumeName,
          },
        },
        spec+: {
          type: 'ClusterIP',
        },
      },

    deployment+:
      {
        spec+: {
          replicas: 1,
          template+: {
            spec+: {
              containers:
                std.map(
                  function(c)
                    if c.name == 'prometheus-adapter' then
                      c
                      {
                        args: [
                          // Keeping until decided how to move on: https://github.com/DirectXMan12/k8s-prometheus-adapter/issues/144
                          // '--prometheus-ca-file=%s/%s' % [servingCertsCABundleMountPath, servingCertsCABundleFileName],
                          // '--prometheus-token-file=/var/run/secrets/kubernetes.io/serviceaccount/token',
                          '--prometheus-auth-config=%s/%s' % [prometheusAdapterPrometheusConfigPath, 'prometheus-config.yaml'],
                          '--config=/etc/adapter/config.yaml',
                          '--logtostderr=true',
                          '--metrics-relist-interval=1m',
                          '--prometheus-url=' + $._config.prometheusAdapter.prometheusURL,
                          '--secure-port=6443',
                        ],
                        terminationMessagePolicy: 'FallbackToLogsOnError',
                        volumeMounts: [
                          containerVolumeMount.new('tmpfs', '/tmp'),
                          containerVolumeMount.new('config', '/etc/adapter'),
                          containerVolumeMount.new(prometheusAdapterPrometheusConfig, prometheusAdapterPrometheusConfigPath),
                          containerVolumeMount.new(servingCertsCABundle, servingCertsCABundleMountPath),
                        ],
                        resources: {
                          requests: {
                            memory: '25Mi',
                            cpu: '1m',
                          },
                        },
                      }
                    else
                      c,
                  super.containers,
                ),

              volumes: [
                volume.fromEmptyDir(name='tmpfs'),
                { name: 'config', configMap: { name: 'adapter-config' } },
                volume.withName(prometheusAdapterPrometheusConfig) + volume.mixin.configMap.withName(prometheusAdapterPrometheusConfig),
                volume.withName(servingCertsCABundle) + volume.mixin.configMap.withName('serving-certs-ca-bundle'),
              ],
              securityContext: {},
              priorityClassName: 'system-cluster-critical',
            },
          },
        },
      },

    clusterRoleBindingView:
      local clusterRoleBinding = k.rbac.v1.clusterRoleBinding;

      clusterRoleBinding.new() +
      clusterRoleBinding.mixin.metadata.withName('prometheus-adapter-view') +
      clusterRoleBinding.mixin.roleRef.withApiGroup('rbac.authorization.k8s.io') +
      clusterRoleBinding.mixin.roleRef.withName('cluster-monitoring-view') +
      clusterRoleBinding.mixin.roleRef.mixinInstance({ kind: 'ClusterRole' }) +
      clusterRoleBinding.withSubjects([{
        kind: 'ServiceAccount',
        name: 'prometheus-adapter',
        namespace: $._config.namespace,
      }]),

    configmapPrometheus:
      local config = |||
        apiVersion: v1
        clusters:
        - cluster:
            certificate-authority: %s
            server: %s
          name: prometheus-k8s
        contexts:
        - context:
            cluster: prometheus-k8s
            user: prometheus-k8s
          name: prometheus-k8s
        current-context: prometheus-k8s
        kind: Config
        preferences: {}
        users:
        - name: prometheus-k8s
          user:
            tokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
      ||| % [
        servingCertsCABundleMountPath + '/' + servingCertsCABundleFileName,
        $._config.prometheusAdapter.prometheusURL,
      ];

      configmap.new(prometheusAdapterPrometheusConfig, { 'prometheus-config.yaml': config }) +
      configmap.mixin.metadata.withNamespace($._config.namespace),
  },
}
