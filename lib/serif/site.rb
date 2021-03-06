
module Liquid #:nodoc:#
module StandardFilters #:nodoc:#
  alias_method :date_orig, :date

  def date(input, format)
    input == "now" ? date_orig(Time.now, format) : date_orig(input, format)
  end
end
end

module Serif
module Filters
  def strip(input)
    input.strip
  end

  def encode_uri_component(string)
    return "" unless string
    CGI.escape(string)
  end

  def smarty(text)
    text.gsub!('`', '\\\\`')
    Redcarpet::Render::SmartyPants.render(text)
  end

  def markdown(body)
    renderer = Redcarpet::Markdown.new(Serif::MarkupRenderer, fenced_code_blocks: true)
    html = renderer.render(body).strip

    # make sure we aren't overriding unless we need to.
    # causes the workaround to automatically turn off.
    if !(renderer.render("a 'quoted' word").include?("&rsquo;"))
      # fix the broken single curly quotes by putting them back
      # as unescaped characters and then re-running the renderer.
      html.gsub!("&#39;", "'")
      html = renderer.render(html)
    end

    html
  end

  def xmlschema(input)
    input.xmlschema
  end
end

class FileDigest < Liquid::Tag
  DIGEST_CACHE = {}

  # file_digest "file.css" [prefix:.]
  Syntax = /^\s*(\S+)\s*(?:(prefix\s*:\s*\S+)\s*)?$/

  def initialize(tag_name, markup, tokens)
    super

    if markup =~ Syntax
      @path = $1

      if $2
        @prefix = $2.gsub(/\s*prefix\s*:\s*/, "")
      else
        @prefix = ""
      end
    else
      raise SyntaxError.new("Syntax error for file_digest")
    end
  end

  # Takes the given path and returns the MD5
  # hex digest of the file's contents.
  #
  # The path argument is first stripped, and any leading
  # "/" has no effect.
  def render(context)
    return "" unless ENV["ENV"] == "production"

    full_path = File.join(context["site"]["directory"], @path.strip)
    
    return @prefix + DIGEST_CACHE[full_path] if DIGEST_CACHE[full_path]

    digest = Digest::MD5.hexdigest(File.read(full_path))
    DIGEST_CACHE[full_path] = digest

    @prefix + digest
  end
end
end

Liquid::Template.register_filter(Serif::Filters)
Liquid::Template.register_tag("file_digest", Serif::FileDigest)

module Serif
class Site
  def initialize(source_directory)
    @source_directory = source_directory
  end

  def directory
    @source_directory
  end

  # Returns all of the site's posts, in reverse chronological order
  # by creation time.
  def posts
    Post.all(self).sort_by { |entry| entry.created }.reverse
  end

  def drafts
    Draft.all(self)
  end

  def config
    @config ||= Serif::Config.new(File.join(@source_directory, "_config.yml"))
  end

  def site_path(path)
    File.join("_site", path)
  end

  def tmp_path(path)
    File.join("tmp", site_path(path))
  end

  def latest_update_time
    most_recent = posts.max_by { |p| p.updated }
    most_recent ? most_recent.updated : Time.now
  end

  # Gives the URL absolute path to a private draft preview.
  #
  # If the draft has no such preview available, returns nil.
  def private_url(draft)
    private_draft_pattern = site_path("/drafts/#{draft.slug}/*")
    file = Dir[private_draft_pattern].first

    return nil unless file

    "/drafts/#{draft.slug}/#{File.basename(file, ".html")}"
  end

  def bypass?(filename)
    !%w[.html .xml].include?(File.extname(filename))
  end

  # Returns the relative archive URL for the given date,
  # using the value of config.archive_url_format
  def archive_url_for_date(date)
    format = config.archive_url_format

    parts = {
      "year" => date.year.to_s,
      "month" => date.month.to_s.rjust(2, "0")
    }

    output = format

    parts.each do |placeholder, value|
      output = output.gsub(Regexp.quote(":" + placeholder), value)
    end

    output
  end

  # Returns a nested hash with the following structure:
  #
  # {
  #   :posts => [],
  #   :years => [
  #     {
  #       :date => Date.new(2012),
  #       :posts => [],
  #       :months => [
  #         { :date => Date.new(2012, 12), :archive_url => "/archive/2012/12", :posts => [] },
  #         { :date => Date.new(2012, 11), :archive_url => "/archive/2012/11", :posts => [] },
  #         # ...
  #       ]
  #     },
  #
  #     # ...
  #  ]
  # }
  def archives
    h = {}
    h[:posts] = posts

    # group posts by Date instances for the first day of the year
    year_groups = posts.group_by { |post| Date.new(post.created.year) }.to_a

    # collect all elements as maps for the year start date and the posts in that year
    year_groups.map! do |year_start_date, posts_by_year|
      {
        :date => year_start_date,
        :posts => posts_by_year.sort_by { |post| post.created }.reverse
      }
    end

    year_groups.sort_by! { |year_hash| year_hash[:date] }
    year_groups.reverse!

    year_groups.each do |year_hash|
      year_posts = year_hash[:posts]

      # group the posts in the year by month
      month_groups = year_posts.group_by { |post| Date.new(post.created.year, post.created.month) }.to_a

      # collect the elements as maps for the month start date and the posts in that month
      month_groups.map! do |month_start_date, posts_by_month|
        {
          :date => month_start_date,
          :posts => posts_by_month.sort_by { |post| post.created }.reverse,
          :archive_url => archive_url_for_date(month_start_date)
        }
      end

      month_groups.sort_by! { |month_hash| month_hash[:date] }
      month_groups.reverse!

      # set the months for the current year
      year_hash[:months] = month_groups
    end

    h[:years] = year_groups

    # return the final hash
    h
  end

  # Returns a hash representing any conflicting URLs,
  # in the form
  #
  #     { "/url_1" => [e_1, e_2, ..., e_n], ... }
  #
  # The elements e_i are the conflicting Post and
  # Draft instances that share the URL "/url_1".
  #
  # Note that if n = 1 (that is, the array value is
  # [e_1], containing a single element), then it is
  # not included in the Hash, since it does not
  # contribute to a conflict.
  #
  # If there are no conflicts found, returns nil.
  #
  # If an argument is specified, its #url value is
  # compared against all post and draft URLs, and
  # the value returned is either:
  #
  # 1. an array of post/draft instances that
  #    conflict, _including_ the argument given; or,
  # 2. nil if there is no conflict.
  def conflicts(content_to_check = nil)
    if content_to_check
      content = drafts + posts + [content_to_check]

      # In the event that the given argument is actually one of the
      # drafts + posts, we need to de-duplicate, otherwise our return
      # value will contain two of the same Draft/Post, which isn't
      # actually a conflict.
      #
      # So to do that, we can use the path on the filesystem. However,
      # we can't just rely on calling #path, because if content_to_check
      # doesn't have a #path value, it'll be nil and it's possible that
      # we might expand checking to multiple files/Drafts/Posts.
      #
      # Thus, if #path is nil, simply rely on object_id.
      #
      # FIXME: Replace this with a proper implementation of
      # ContentFile equality/hashing.
      content.uniq! { |e| e.path ? e.path : e.object_id }

      conflicts = content.select { |e| e.url == content_to_check.url }

      if conflicts.length <= 1
        return nil
      else
        return conflicts
      end
    end

    conflicts = (drafts + posts).group_by { |e| e.url }
    conflicts.reject! { |k, v| v.length == 1 }

    if conflicts.empty?
      nil
    else
      conflicts
    end
  end

  def to_liquid
    @liquid_cache_store ||= TimeoutCache.new(1)

    cached_value = @liquid_cache_store[:liquid]
    return cached_value if cached_value

    @liquid_cache_store[:liquid] = {
      "posts" => posts,
      "latest_update_time" => latest_update_time,
      "archive" => self.class.stringify_keys(archives),
      "directory" => directory
    }
  end

  def generate
    FileUtils.cd(@source_directory)

    FileUtils.rm_rf("tmp/_site")
    FileUtils.mkdir_p("tmp/_site")

    files = Dir["**/*"].select { |f| f !~ /\A_/ && File.file?(f) }

    default_layout = Liquid::Template.parse(File.read("_layouts/default.html"))

    if conflicts
      raise PostConflictError, "Generating would cause a conflict."
    end

    # preprocess any drafts marked for autopublish, before grabbing the posts
    # to operate on.
    preprocess_autopublish_drafts

    # preprocess any posts that might have had an update flag set in the header
    preprocess_autoupdate_posts

    posts = self.posts

    files.each do |path|
      puts "Processing file: #{path}"

      dirname = File.dirname(path)
      filename = File.basename(path)

      FileUtils.mkdir_p(tmp_path(dirname))
      if bypass?(filename)
        FileUtils.cp(path, tmp_path(path))
      else
        File.open(tmp_path(path), "w") do |f|
          file = File.read(path)
          title = nil
          layout_option = :default

          if Redhead::String.has_headers?(file)
            file_with_headers = Redhead::String[file]
            title = file_with_headers.headers[:title] && file_with_headers.headers[:title].value
            layout_option = file_with_headers.headers[:layout] && file_with_headers.headers[:layout].value
            layout_option ||= :default

            # all good? use the headered string
            file = file_with_headers
          end

          if layout_option == "none"
            f.puts Liquid::Template.parse(file.to_s).render!("site" => self)
          else
            if layout_option == :default
              layout = default_layout
            else
              layout_file = File.join(self.directory, "_layouts", "#{layout_option}.html")
              layout = Liquid::Template.parse(File.read(layout_file))
            end
            f.puts layout.render!("site" => self, "page" => { "title" => title }, "content" => Liquid::Template.parse(file.to_s).render!("site" => self))
          end
        end
      end
    end

    # run through the posts + nil so we can keep |a, b| such that a hits every element
    # while iterating.
    posts.each.with_index do |post, i|
      # the posts are iterated over in reverse chrological order, and
      # next_post here is post published chronologically after than
      # the post in the iteration.
      #
      # if i == 0, we don't want posts.last, so return nil if i - 1 == -1
      next_post = (i == 0 ? nil : posts[i - 1])
      prev_post = posts[i + 1]

      puts "Processing post: #{post.path}"

      FileUtils.mkdir_p(tmp_path(File.dirname(post.url)))

      post_layout = default_layout

      if post.headers[:layout]
        post_layout = Liquid::Template.parse(File.read(File.join(self.directory, "_layouts", "#{post.headers[:layout]}.html")))
      end

      File.open(tmp_path(post.url + ".html"), "w") do |f|
        # variables available in the post template
        post_template_variables = {
          "post" => post,
          "post_page" => true,
          "prev_post" => prev_post,
          "next_post" => next_post
        }

        f.puts post_layout.render!(
          "site" => self,
          "page" => { "title" => post.title },
          "post_page" => true,
          "content" => Liquid::Template.parse(File.read("_templates/post.html")).render!(post_template_variables)
        )
      end
    end

    generate_draft_previews(default_layout)

    generate_archives(default_layout)

    if Dir.exist?("_site")
      FileUtils.mv("_site", "/tmp/_site.#{Time.now.strftime("%Y-%m-%d-%H-%M-%S.%6N")}")
    end

    FileUtils.mv("tmp/_site", ".") && FileUtils.rm_rf("tmp/_site")
    FileUtils.rmdir("tmp")
  end

  private

  def preprocess_autoupdate_posts
    posts.each do |p|
      if p.autoupdate?
        puts "Auto-updating timestamp for: #{p.title} / #{p.slug}"
        p.update!
      end
    end
  end

  # generates draft preview files for any unpublished drafts.
  #
  # uses the same template as live posts.
  def generate_draft_previews(layout)
    drafts = self.drafts

    template = Liquid::Template.parse(File.read("_templates/post.html"))

    # publish each draft under a randomly generated name, or use the
    # existing file if one is present.
    drafts.each do |draft|
      url = private_url(draft)
      if url
        # take our existing URL like /drafts/foo/<random> (without .html)
        # and give the filename
        file = File.basename(url)
      else
        # create a new name
        file = SecureRandom.hex(30)
      end

      # convert the name into a relative path
      file = "drafts/#{draft.slug}/#{file}"

      # the absolute path in the site's tmp path, where we create the file
      # ready to be deployed.
      live_preview_file = tmp_path(file)
      FileUtils.mkdir_p(File.dirname(live_preview_file))

      puts "#{url ? "Updating" : "Creating"} draft preview: #{file}"

      File.open(live_preview_file + ".html", "w") do |f|
        f.puts layout.render!(
          "site" => self,
          "draft_preview" => true,
          "page" => { "title" => draft.title },
          "content" => template.render!("site" => self, "post" => draft, "draft_preview" => true)
        )
      end
    end
  end

  # goes through all draft posts that have "publish: now" headers and
  # calls #publish! on each one
  def preprocess_autopublish_drafts
    puts "Beginning pre-process step for drafts."
    drafts.each do |d|
      if d.autopublish?
        puts "Autopublishing draft: #{d.title} / #{d.slug}"
        d.publish!
      end
    end
  end

  # Uses config.archive_url_format to generate pages
  # using the archive_page.html template.
  def generate_archives(layout)
    return unless config.archive_enabled?

    template = Liquid::Template.parse(File.read("_templates/archive_page.html"))

    months = posts.group_by { |post| Date.new(post.created.year, post.created.month) }

    months.each do |month, posts|
      archive_path = tmp_path(archive_url_for_date(month))
      
      FileUtils.mkdir_p(archive_path)

      File.open(File.join(archive_path + ".html"), "w") do |f|
        f.puts layout.render!("archive_page" => true, "month" => month, "site" => self, "content" => template.render!("archive_page" => true, "site" => self, "month" => month, "posts" => posts))
      end
    end
  end

  def self.stringify_keys(obj)
    return obj unless obj.is_a?(Hash) || obj.is_a?(Array)

    if obj.is_a?(Array)
      return obj.map do |el|
        stringify_keys(el)
      end
    end

    result = {}
    obj.each do |key, value|
      result[key.to_s] = stringify_keys(value)
    end
    result
  end
end
end