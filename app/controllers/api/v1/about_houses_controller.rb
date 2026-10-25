module Api
  module V1
    # The sheet a resident reads to say what this house is (#566). Any
    # authenticated key may read it: it holds nothing about an account, only
    # what this release offers. Plain Markdown, so the runtime can write it
    # to disk as it comes.
    class AboutHousesController < BaseController

      def show
        render plain: AboutSheet.render, content_type: "text/markdown"
      end

    end
  end
end
