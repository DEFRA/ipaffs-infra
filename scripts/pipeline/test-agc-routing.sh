#!/bin/bash

set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

# Execute the actual inline pipeline script against local stubs; never contact Azure or Kubernetes.
ruby - "$repository_root" <<'RUBY'
require 'yaml'
require 'open3'
require 'json'

repo = ARGV.fetch(0)
pipeline = YAML.load_file("#{repo}/pipelines/stages/install-helm-charts.yaml")
steps = pipeline.fetch('stages').first.fetch('jobs').first.fetch('strategy').fetch('runOnce').fetch('deploy').fetch('steps')
gateway_index = steps.index { |step| step['displayName'] == 'Helm Install - agc-gateway' }
cert_index = steps.index { |step| step['displayName'] == 'Helm Install - defra-certs' }
nginx_index = steps.index { |step| step['displayName'] == 'Helm Install - app-routing-controller' }
abort 'Gateway must install after certificates and before app-routing-controller' unless cert_index < gateway_index && gateway_index < nginx_index
script = steps.fetch(gateway_index).fetch('inputs').fetch('inlineScript')
common = YAML.load_file("#{repo}/pipelines/vars/common.yaml")
abort 'Gateway must remain opt-in by default' unless common.fetch('variables').fetch('appGatewayForContainersGatewayEnabled') == false

resource_id = '/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/PRDIMPINFRG1401/providers/Microsoft.ServiceNetworking/trafficControllers/PRDIMPINFAG1401'
outputs = {appGatewayForContainersResourceId: {value: resource_id}, appGatewayForContainersFrontendName: {value: 'public'}}
stubs = <<~'BASH'
  az() {
    [[ "$1 $2 $3" == 'deployment group show' ]] || return 90
    echo 'READ_CURRENT_DEPLOYMENT' >&2
    [[ "$AZURE_FAIL" == false ]] || return 91
    echo "$MOCK_OUTPUTS"
  }
  helm() { printf 'HELM_ARG:%s\n' "$@"; }
  kubectl() {
    [[ "$1" == wait ]] || return 92
    printf 'KUBECTL_ARG:%s\n' "$@"
    [[ "$2" != "$KUBERNETES_FAIL_CONDITION" ]] || return 93
  }
BASH

tests = [
  {name: 'disabled needs no infrastructure outputs', env: {'AGC_GATEWAY_ENABLED' => 'False', 'AGC_RESOURCE_ID' => '$(appGatewayForContainersResourceId)', 'AGC_FRONTEND_NAME' => '$(appGatewayForContainersFrontendName)', 'INFRASTRUCTURE_DEPLOYMENT_NAME' => '$(unresolved)'}, pass: true, has: ['enabled=false'], lacks: ['READ_CURRENT_DEPLOYMENT', 'KUBECTL_ARG:', 'resourceId=']},
  {name: 'combined deployment uses fresh outputs', env: {'INFRASTRUCTURE_DEPLOYMENT_NAME' => 'Infrastructure-123', 'AGC_RESOURCE_ID' => '$(appGatewayForContainersResourceId)'}, pass: true, has: ['READ_CURRENT_DEPLOYMENT', "resourceId=#{resource_id}", 'allowedNamespaces[0]=prd', 'externalsecret/star-azure-defra-cloud-cert', '--for=condition=Accepted', '--for=condition=Programmed']},
  {name: 'standalone uses saved outputs', pass: true, has: ["resourceId=#{resource_id}", 'frontendName=public'], lacks: ['READ_CURRENT_DEPLOYMENT']},
  {name: 'dry run uses valid saved outputs without waits', env: {'HELM_DRY_RUN' => '--dry-run', 'INFRASTRUCTURE_DEPLOYMENT_NAME' => 'Infrastructure-123'}, pass: true, has: ['HELM_ARG:--dry-run', "resourceId=#{resource_id}"], lacks: ['READ_CURRENT_DEPLOYMENT', 'KUBECTL_ARG:']},
  {name: 'enabled dry run refuses missing AGC ID', env: {'HELM_DRY_RUN' => '--dry-run', 'AGC_RESOURCE_ID' => ''}, pass: false, has: ['valid appGatewayForContainersResourceId'], lacks: ['HELM_ARG:']},
  {name: 'unresolved AGC ID refused', env: {'AGC_RESOURCE_ID' => '$(appGatewayForContainersResourceId)'}, pass: false, has: ['valid appGatewayForContainersResourceId'], lacks: ['HELM_ARG:']},
  {name: 'unresolved frontend refused', env: {'AGC_FRONTEND_NAME' => '$(appGatewayForContainersFrontendName)'}, pass: false, has: ['valid appGatewayForContainersFrontendName'], lacks: ['HELM_ARG:']},
  {name: 'unresolved deployment name refused', env: {'INFRASTRUCTURE_DEPLOYMENT_NAME' => '$(deploymentName)'}, pass: false, has: ['Unresolved infrastructureDeploymentName'], lacks: ['HELM_ARG:', 'READ_CURRENT_DEPLOYMENT']},
  {name: 'failed current deployment read does not use stale Library', env: {'INFRASTRUCTURE_DEPLOYMENT_NAME' => 'Infrastructure-123', 'AZURE_FAIL' => 'true'}, pass: false, lacks: ['HELM_ARG:']},
  {name: 'certificate readiness failure prevents Gateway deployment', env: {'KUBERNETES_FAIL_CONDITION' => '--for=condition=Ready'}, pass: false, has: ['externalsecret/star-azure-defra-cloud-cert'], lacks: ['HELM_ARG:']},
  {name: 'unprogrammed Gateway fails the deployment', env: {'KUBERNETES_FAIL_CONDITION' => '--for=condition=Programmed'}, pass: false, has: ['HELM_ARG:upgrade', '--for=condition=Programmed']},
  {name: 'invalid flag refused', env: {'AGC_GATEWAY_ENABLED' => '$(appGatewayForContainersGatewayEnabled)'}, pass: false, has: ['must be true or false'], lacks: ['HELM_ARG:']}
]
%w[DEV TST PRE PRD].each do |environment|
  tests << {name: "#{environment} namespace selection", environment: environment, pass: true, has: ["allowedNamespaces[0]=#{environment.downcase}"]}
  environment_variables = YAML.load_file("#{repo}/pipelines/vars/#{environment.downcase}.yaml").fetch('variables')
  effective_variables = common.fetch('variables').merge(environment_variables)
  enabled = effective_variables.fetch('appGatewayForContainersGatewayEnabled')
  abort "Only DEV should currently opt in to the shared Gateway" unless enabled == (environment == 'DEV')
  tests << {
    name: "#{environment} configured Gateway rollout",
    environment: environment,
    env: {'AGC_GATEWAY_ENABLED' => enabled.to_s, 'HELM_DRY_RUN' => '--dry-run'},
    pass: true,
    has: ["enabled=#{enabled}", 'HELM_ARG:--dry-run'],
    lacks: enabled ? ['KUBECTL_ARG:'] : ['KUBECTL_ARG:', 'resourceId=', 'allowedNamespaces[0]=']
  }
end

tests.each do |test|
  env = {'AGC_GATEWAY_ENABLED' => 'true', 'AGC_RESOURCE_ID' => resource_id, 'AGC_FRONTEND_NAME' => 'public', 'HELM_DRY_RUN' => '', 'INFRASTRUCTURE_DEPLOYMENT_NAME' => '', 'MOCK_OUTPUTS' => outputs.to_json, 'AZURE_FAIL' => 'false', 'KUBERNETES_FAIL_CONDITION' => ''}.merge(test.fetch(:env, {}))
  rendered = script.gsub('$(subscriptionId)', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
    .gsub('$(resourceGroupName)', 'PRDIMPINFRG1401')
    .gsub('$(helmDryRun)', env.fetch('HELM_DRY_RUN'))
    .gsub('${{ lower(parameters.environmentName) }}', test.fetch(:environment, 'PRD').downcase)
  stdout, stderr, status = Open3.capture3(env, '/bin/bash', stdin_data: stubs + rendered, chdir: repo)
  output = stdout + stderr
  abort "#{test[:name]}: unexpected status #{status.exitstatus}\n#{output}" unless status.success? == test[:pass]
  test.fetch(:has, []).each { |value| abort "#{test[:name]}: missing #{value}\n#{output}" unless output.include?(value) }
  test.fetch(:lacks, []).each { |value| abort "#{test[:name]}: unexpected #{value}\n#{output}" if output.include?(value) }
  puts "PASS #{test[:name]}"
end
RUBY
