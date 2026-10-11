require "test_helper"

class XTextLengthTest < ActiveSupport::TestCase

  test "latin text counts one per character" do
    assert_equal 5, XTextLength.weighted_length("hello")
    assert XTextLength.valid?("a" * 280)
    assert_not XTextLength.valid?("a" * 281)
  end

  test "CJK characters count double, so 140 fill the post" do
    assert_equal 4, XTextLength.weighted_length("日本")
    assert XTextLength.valid?("字" * 140)
    assert_not XTextLength.valid?("字" * 141)
  end

  test "an emoji grapheme counts two, including a joined family" do
    assert_equal 2, XTextLength.weighted_length("🙂")
    assert_equal 2, XTextLength.weighted_length("👨‍👩‍👧")
  end

  test "every URL counts 23 whatever its length" do
    long_url = "https://example.com/#{"a" * 200}"
    assert_equal 23 + 1 + 2, XTextLength.weighted_length("#{long_url} hi")
    assert XTextLength.valid?("#{long_url} #{"b" * 250}")
  end

  test "text is NFC normalised before counting" do
    assert_equal 1, XTextLength.weighted_length("é")
  end

  test "blank text is not valid" do
    assert_not XTextLength.valid?("   ")
  end

end
