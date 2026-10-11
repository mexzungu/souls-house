# X's weighted post length (twitter-text configuration v3): text is NFC
# normalised, every URL counts as 23, an emoji grapheme counts as 2, code
# points in the light ranges (Latin and common punctuation) count as 1 and
# everything else, including CJK, counts as 2. The limit is 280 weighted units.
module XTextLength

  MAX_WEIGHTED_LENGTH = 280
  URL_WEIGHT = 23
  LIGHT_RANGES = [ 0..4351, 8192..8205, 8208..8223, 8242..8247 ].freeze
  URL_PATTERN = %r{\bhttps?://[^\s]+|\b(?:www\.)?[a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)*\.(?:com|org|net|io|co|ai|dev|app|house|uk|me|ly|gg)(?:/[^\s]*)?}i

  module_function

  def weighted_length(text)
    normalized = text.to_s.unicode_normalize(:nfc)
    total = 0
    rest = normalized.gsub(URL_PATTERN) do
      total += URL_WEIGHT
      ""
    end
    rest.each_grapheme_cluster do |grapheme|
      total += grapheme_weight(grapheme)
    end
    total
  end

  def valid?(text)
    stripped = text.to_s.strip
    stripped.present? && weighted_length(stripped) <= MAX_WEIGHTED_LENGTH
  end

  def grapheme_weight(grapheme)
    return 2 if grapheme.match?(/\p{Extended_Pictographic}/)

    grapheme.each_codepoint.sum do |codepoint|
      LIGHT_RANGES.any? { |range| range.cover?(codepoint) } ? 1 : 2
    end
  end

end
