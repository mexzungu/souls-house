namespace :about_sheet do
  desc "Write the about-souls-house sheet baked into the runtime image (#566)"
  task bake: :environment do
    sha = `git rev-parse --short HEAD 2>/dev/null`.strip.presence
    version = [ Rails.application.version.to_s, sha ].compact.join(" ")
    path = Rails.root.join("agent-runtime/docs/about-souls-house.md")
    path.write(AboutSheet.render(version: version, billing_open: :unknown, baked: true))
    puts "Wrote #{path.relative_path_from(Rails.root)} (#{path.size} bytes)"
  end
end
