# Run using bin/ci

CI.run do
  quality_gate_steps = [
    [ "Dependencies: Locked bundle", "bundle", "check" ],
    [ "Security: Gem audit", "bin/bundler-audit", "check", "--update" ],
    [ "Security: Importmap vulnerability audit", "bin/importmap", "audit" ],
    [ "Style: Ruby", "bin/rubocop" ],
    [ "Database: Prepare test database", "bin/rails", "db:prepare" ],
    [ "Assets: Tailwind CSS", "bin/rails", "tailwindcss:build" ],
    [ "Tests: Rails", "bin/rails", "test" ],
    [ "Autoloading", "bin/rails", "zeitwerk:check" ],
    [ "Security: Brakeman code analysis", "bin/brakeman", "--quiet", "--no-pager", "--exit-on-warn", "--exit-on-error" ]
  ]

  system_test_pattern = File.expand_path("../test/system/**/*_test.rb", __dir__)
  if Dir[system_test_pattern].any?
    quality_gate_steps.insert(7, [ "Tests: System", "bin/rails", "test:system" ])
  end

  quality_gate_steps.each do |title, *command|
    step title, *command
    break unless success?
  end

  # Optional: set a green GitHub commit status to unblock PR merge.
  # Requires the `gh` CLI and `gh extension install basecamp/gh-signoff`.
  # if success?
  #   step "Signoff: All systems go. Ready for merge and deploy.", "gh signoff"
  # else
  #   failure "Signoff: CI failed. Do not merge or deploy.", "Fix the issues and try again."
  # end
end
