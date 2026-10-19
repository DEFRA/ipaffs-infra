require "open3"
require "yaml"

chart = File.expand_path("..", __dir__)
values_file = File.join(__dir__, "ci-values.yaml")
args = ["helm", "template", "pdb-selection", chart, "--values", values_file]
args += [
  "--set", "database.migrations.enabled=true",
  "--set-string", "database.migrations.clientId=00000000-0000-0000-0000-000000000002",
  "--set-string", "database.migrations.image=test/migrations:1.0.0"
]
rendered, errors, status = Open3.capture3(*args)
abort "#{errors}#{rendered}" unless status.success?
resources = YAML.load_stream(rendered).compact
resource = lambda do |kind|
  matches = resources.select { |item| item["kind"] == kind }
  abort "Expected one rendered #{kind}, found #{matches.length}" unless matches.length == 1
  matches.first
end
selector = resource.call("PodDisruptionBudget").fetch("spec").fetch("selector")
application_labels = resource.call("Deployment").dig("spec", "template", "metadata", "labels")
migration = resource.call("Job")
migration_labels = migration.dig("spec", "template", "metadata", "labels").dup
job_keys = ["batch.kubernetes.io/job-name", "job-name"]
job_keys.each { |key| migration_labels.delete(key) }

matches = lambda do |labels|
  selector.fetch("matchLabels", {}).all? { |key, value| labels[key] == value } &&
    selector.fetch("matchExpressions", []).all? do |expression|
      key = expression.fetch("key")
      values = expression.fetch("values", [])
      case expression.fetch("operator")
      when "In" then labels.key?(key) && values.include?(labels[key])
      when "NotIn" then !values.include?(labels[key])
      when "Exists" then labels.key?(key)
      when "DoesNotExist" then !labels.key?(key)
      else abort "Unsupported selector operator: #{expression['operator']}"
      end
    end
end

checks = { "application pod" => [application_labels, true] }
# Kubernetes adds Job labels to Pods; exercise current and legacy label variants.
[job_keys, [job_keys.first], [job_keys.last]].each do |keys|
  labels = migration_labels.merge(keys.to_h { |key| [key, migration.fetch("metadata").fetch("name")] })
  checks["migration pod with #{keys.join(' and ')}"] = [labels, false]
end
["app.kubernetes.io/name", "app.kubernetes.io/part-of"].each do |key|
  checks["application pod with a different #{key}"] = [application_labels.merge(key => "another-value"), false]
end
checks.each do |name, (labels, expected)|
  abort "Unexpected disruption budget selection for #{name}" unless matches.call(labels) == expected
end
puts "Validated #{checks.length} disruption budget selection cases."
