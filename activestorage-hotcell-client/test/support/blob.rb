# frozen_string_literal: true

# Enough of an ActiveStorage::Blob for an analyzer and a previewer to work with.
#
# A real one needs a database, a service, and a booted application. What these classes actually touch is four
# methods, and standing those up is the difference between a suite that runs in a second and one that needs a
# dummy app.
class Blob
  Filename = Struct.new(:name) do
    def base
      File.basename name, File.extname(name)
    end

    def to_s
      name
    end
  end

  attr_reader :path, :content_type

  def initialize(path, content_type: nil)
    @path = path
    @content_type = content_type || guess_content_type(path)
  end

  def filename
    Filename.new File.basename(path)
  end

  def image?
    content_type.start_with? "image/"
  end

  def video?
    content_type.start_with? "video/"
  end

  def audio?
    content_type.start_with? "audio/"
  end

  # Yields a copy, as the real one does: Blob#open downloads to a tempfile rather than handing out the original.
  def open(tmpdir: nil, &block)
    Tempfile.create([ "blob", File.extname(path) ], tmpdir, binmode: true) do |file|
      IO.copy_stream path, file
      file.flush
      file.rewind
      block.call file
    end
  end

  private
    def guess_content_type(path)
      case File.extname(path).downcase
      when ".png" then "image/png"
      when ".jpg", ".jpeg" then "image/jpeg"
      when ".gif" then "image/gif"
      when ".svg" then "image/svg+xml"
      when ".pdf" then "application/pdf"
      when ".mp4" then "video/mp4"
      when ".mp3" then "audio/mpeg"
      else "application/octet-stream"
      end
    end
end
