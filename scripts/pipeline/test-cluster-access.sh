#!/bin/bash

set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

# Exercise the actual pipeline script with a Helm stub; no Azure or Kubernetes calls are made.
ruby - "$repository_root" <<'RUBY'
require 'yaml'
require 'open3'

repo = ARGV.fetch(0)
pipeline = YAML.load_file("#{repo}/pipelines/stages/install-helm-charts.yaml")
steps = pipeline.fetch('stages').first.fetch('jobs').first.fetch('strategy').fetch('runOnce').fetch('deploy').fetch('steps')
install_index = steps.index { |step| step['displayName'] == 'Helm Install - cluster-access' }
authentication_index = steps.index { |step| step['name'] == 'AuthenticateAzure' }
abort 'Cluster access chart must install after authentication' unless authentication_index < install_index
install = steps.fetch(install_index)
abort 'Exec flag must come from the environment configuration' unless install.fetch('env').fetch('KUBECTL_EXEC_ENABLED') == '$(kubectlExecEnabled)'
abort 'Port forwarding flag must come from the environment configuration' unless install.fetch('env').fetch('KUBECTL_PORT_FORWARD_ENABLED') == '$(kubectlPortForwardEnabled)'
abort 'Chart installation must use the pipeline dry run setting' unless install.fetch('env').fetch('HELM_DRY_RUN') == '$(helmDryRun)'
script = install.fetch('inputs').fetch('inlineScript')

standalone = YAML.load_file("#{repo}/pipelines/install-helm-charts.yaml")
%w[trigger pr].each do |trigger|
  paths = standalone.fetch(trigger).fetch('paths').fetch('include')
  ['helm-charts/cluster-access/**', *%w[dev tst pre prd].map { |env| "pipelines/vars/#{env}.yaml" }].each do |path|
    abort "#{trigger} must cover #{path}" unless paths.include?(path)
  end
end
%w[infrastructure install-helm-charts].each do |name|
  source = YAML.load_file("#{repo}/pipelines/#{name}.yaml")
  abort "#{name} must install the cluster charts" unless source.fetch('stages').any? { |stage| stage['template'] == 'stages/install-helm-charts.yaml' }
  dry_run = source.fetch('variables').find { |variable| variable['name'] == 'helmDryRun' }
  main = "${{ if eq(variables['Build.SourceBranch'], 'refs/heads/main') }}"
  abort "#{name} must keep non-main deployments as dry runs" unless dry_run.fetch(main).fetch('value') == '' && dry_run.fetch('${{ else }}').fetch('value') == '--dry-run'
end

stubs = <<~'BASH'
  helm() { printf 'HELM_ARG:%s\n' "$@"; }
BASH

tests = []
%w[dev tst pre prd].each do |environment|
  variables = YAML.load_file("#{repo}/pipelines/vars/#{environment}.yaml").fetch('variables')
  flags = %w[kubectlExecEnabled kubectlPortForwardEnabled].to_h do |flag|
    value = variables.fetch(flag)
    abort "#{environment}: #{flag} must be an explicit boolean" unless [true, false].include?(value)
    abort "#{environment}: #{flag} must be #{environment == 'dev'}" unless value == (environment == 'dev')
    [flag, value.to_s]
  end
  tests << {name: "#{environment} configured capabilities", env: {'KUBECTL_EXEC_ENABLED' => flags.fetch('kubectlExecEnabled'), 'KUBECTL_PORT_FORWARD_ENABLED' => flags.fetch('kubectlPortForwardEnabled')}, has: ["kubectlExecEnabled=#{flags.fetch('kubectlExecEnabled')}", "kubectlPortForwardEnabled=#{flags.fetch('kubectlPortForwardEnabled')}"]}
end
%w[true false].product(%w[true false]).each do |exec_enabled, port_forward_enabled|
  tests << {name: "independent capabilities #{exec_enabled}/#{port_forward_enabled}", env: {'KUBECTL_EXEC_ENABLED' => exec_enabled, 'KUBECTL_PORT_FORWARD_ENABLED' => port_forward_enabled}, has: ["kubectlExecEnabled=#{exec_enabled}", "kubectlPortForwardEnabled=#{port_forward_enabled}"]}
end
tests += [
  {name: 'pipeline booleans are normalized', env: {'KUBECTL_EXEC_ENABLED' => 'True', 'KUBECTL_PORT_FORWARD_ENABLED' => 'False'}, has: ['kubectlExecEnabled=true', 'kubectlPortForwardEnabled=false']},
  {name: 'dry run is forwarded', env: {'HELM_DRY_RUN' => '--dry-run'}, has: ['HELM_ARG:--dry-run']},
  {name: 'unresolved exec flag fails before Helm', env: {'KUBECTL_EXEC_ENABLED' => '$(kubectlExecEnabled)'}, fails: true, has: ['kubectlExecEnabled must be true or false.']},
  {name: 'invalid port forwarding flag fails before Helm', env: {'KUBECTL_PORT_FORWARD_ENABLED' => 'yes'}, fails: true, has: ['kubectlPortForwardEnabled must be true or false.']},
  {name: 'unresolved dry run setting fails before Helm', env: {'HELM_DRY_RUN' => '$(helmDryRun)'}, fails: true, has: ['helmDryRun must be empty or --dry-run.']}
]

tests.each do |test|
  env = {'KUBECTL_EXEC_ENABLED' => 'true', 'KUBECTL_PORT_FORWARD_ENABLED' => 'true', 'HELM_DRY_RUN' => ''}.merge(test.fetch(:env))
  stdout, stderr, status = Open3.capture3(env, '/bin/bash', stdin_data: stubs + script, chdir: repo)
  output = stdout + stderr
  abort "#{test[:name]}: unexpected status #{status.exitstatus}\n#{output}" unless status.success? == !test.fetch(:fails, false)
  test.fetch(:has).each { |value| abort "#{test[:name]}: missing #{value}\n#{output}" unless output.include?(value) }
  if test.fetch(:fails, false)
    abort "#{test[:name]}: Helm must not run with invalid settings\n#{output}" if output.include?('HELM_ARG:')
  else
    %w[upgrade --install --set cluster-access ./helm-charts/cluster-access kube-system].each do |argument|
      abort "#{test[:name]}: missing Helm argument #{argument}\n#{output}" unless output.include?("HELM_ARG:#{argument}\n")
    end
    abort "#{test[:name]}: flags must be typed booleans" if output.include?('HELM_ARG:--set-string')
    abort "#{test[:name]}: live installation must not use dry run" if env.fetch('HELM_DRY_RUN').empty? && output.include?('HELM_ARG:--dry-run')
  end
  puts "PASS #{test[:name]}"
end
RUBY
