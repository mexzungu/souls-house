require "digest"

module Agents
  # A GitHub import's reviewed home, kept in the house until its VM is seeded
  # from it (docs/2026-10-10-vm-imports.md, "Home source": reviewed checkout ->
  # identity). The checkout exists only inside GithubImportSource#with_checkout;
  # this keeps the identity role's archive past it, as AgentImportStage keeps
  # an archive import's three roles, so a retry seeds the same bytes. The
  # files are exactly those a house volume is seeded with
  # (Agents::Volume.home_entries!), under the runner's seed limits.
  module GithubImportStage

    class Error < StandardError; end

    ROLE = "identity".freeze

    module_function

    # The gzip tarball of the checkout and its digest, built before any
    # admission lock is taken. Refused, not truncated, past the runner's limits.
    def pack(root)
      entries = Agents::Volume.home_entries!(root)
      files = entries.count { |_, item| item["type"] == "file" }
      unpacked = entries.sum { |_, item| item["type"] == "file" ? item["size"] : 0 }
      raise Error, "The reviewed home has more files than a resident server can be seeded with" if entries.size > Agents::Portability::Stage.max_role_entries
      raise Error, "The reviewed home is larger than a resident server can be seeded with" if unpacked > Agents::Portability::Stage.max_role_unpacked

      Dir.mktmpdir("github-resident-stage-") do |dir|
        path = File.join(dir, "identity.tar.gz")
        Agents::Portability::Archive.pack(root, entries, path)
        raise Error, "The reviewed home is larger than a resident server can be seeded with" if File.size(path) > Agents::VmSeed::MAX_BYTES

        bytes = File.binread(path)
        { archive: bytes, sha256: Digest::SHA256.hexdigest(bytes), bytes: bytes.bytesize, files: }
      end
    rescue Agents::Volume::SeedError, Agents::Portability::Error => error
      raise Error, error.message
    end

    # Records a packed home for the resident. Kept, never replaced: a retry
    # names the bytes that were reviewed and staged the first time.
    def persist!(agent, packed)
      agent.import_stages.find_by(role: ROLE) ||
        agent.import_stages.create!(role: ROLE, archive: packed[:archive], sha256: packed[:sha256], bytes: packed[:bytes])
    end

  end
end
