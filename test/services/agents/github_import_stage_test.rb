require "test_helper"

# A GitHub import's reviewed checkout, staged for its VM
# (docs/2026-10-10-vm-imports.md): the same files a house volume gets.
module Agents
  class GithubImportStageTest < ActiveSupport::TestCase

    setup do
      @root = Dir.mktmpdir("reviewed-home-")
      FileUtils.mkdir_p(File.join(@root, ".git"))
      FileUtils.mkdir_p(File.join(@root, "memory"))
      File.write(File.join(@root, "soul.md"), "I am imported.\n")
      File.write(File.join(@root, ".git", "HEAD"), "ref: refs/heads/main\n")
      File.write(File.join(@root, "memory", "index.md"), "- first\n")
      @agent = agents(:research_assistant)
    end

    teardown { FileUtils.rm_rf(@root) }

    def tar_paths(gzip)
      paths = []
      Gem::Package::TarReader.new(Zlib::GzipReader.new(StringIO.new(gzip))) { |tar| tar.each { |entry| paths << entry.full_name } }
      paths.sort
    end

    test "packs exactly the files a house volume is seeded with, digest and size recorded" do
      packed = GithubImportStage.pack(@root)
      assert_equal Agents::Volume.home_entries!(@root).keys.sort, tar_paths(packed[:archive])
      assert_includes tar_paths(packed[:archive]), ".git/HEAD"
      assert_equal Digest::SHA256.hexdigest(packed[:archive]), packed[:sha256]
      assert_equal packed[:archive].bytesize, packed[:bytes]
    end

    test "a reviewed home holding a name the runner's seed reserves is refused before anything is staged" do
      %w[.souls-house-seed .souls-house-seed-staging/x .souls-house-seed.tmp].each do |name|
        path = File.join(@root, name)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "reviewed bytes")
        error = assert_raises(GithubImportStage::Error) { GithubImportStage.pack(@root) }
        assert_match(/seed reserves/, error.message)
        FileUtils.rm_rf(File.join(@root, name.split("/").first))
      end
      File.write(File.join(@root, "memory", ".souls-house-seed"), "deeper is fine")
      assert GithubImportStage.pack(@root)
    end

    test "links are refused, not followed" do
      File.symlink("/etc/passwd", File.join(@root, "passwd"))
      assert_raises(GithubImportStage::Error) { GithubImportStage.pack(@root) }
    end

    test "a home past the runner's seed limits is refused at import" do
      Agents::Portability::Stage.stub(:max_role_entries, 2) do
        error = assert_raises(GithubImportStage::Error) { GithubImportStage.pack(@root) }
        assert_match(/more files than a resident server/, error.message)
      end
      Agents::Portability::Stage.stub(:max_role_unpacked, 4) do
        assert_raises(GithubImportStage::Error) { GithubImportStage.pack(@root) }
      end
    end

    test "the first staged home is kept; a later pack never replaces it" do
      first = GithubImportStage.persist!(@agent, GithubImportStage.pack(@root))
      File.write(File.join(@root, "soul.md"), "changed\n")
      again = GithubImportStage.persist!(@agent, GithubImportStage.pack(@root))
      assert_equal first, again
      assert_equal [ first.sha256 ], @agent.import_stages.pluck(:sha256)
    end

  end
end
