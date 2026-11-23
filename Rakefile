require "rspec/core/rake_task"

# Two processes: the unit specs run against a fake ::Rails, the engine specs
# boot the real dummy app in spec/dummy. They cannot share one.
namespace :spec do
  RSpec::Core::RakeTask.new(:unit)

  RSpec::Core::RakeTask.new(:engine) do |t|
    t.pattern = "spec/engine/**/*_spec.rb"
    t.rspec_opts = "-O spec/engine/rspec.opts"
  end

  desc "Engine specs with eager loading on, as in production"
  task :engine_eager do
    sh({ "EAGER_LOAD" => "1" }, "bundle exec rspec -O spec/engine/rspec.opts --format progress")
  end
end

desc "Unit and engine specs"
task spec: %w[spec:unit spec:engine spec:engine_eager]

task default: :spec
