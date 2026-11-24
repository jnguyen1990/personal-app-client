require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/filters"

module PersonalAppClient
  # Search for the command palette (PLAT-18): GET /api/search answers this
  # app's own records.
  #
  # Each app answers GET /api/search?q=&limit= with its own results, from the
  # callable in its initializer:
  #
  #     app.search = ->(q, limit:) do
  #       Recipe.where("name LIKE ?", "%#{Recipe.sanitize_sql_like(q)}%").limit(limit).map do |r|
  #         { kind: "Recipe", title: r.name, meta: "30 min · rated 4",
  #           url: "/recipes/#{r.id}",
  #           preview: { heading: r.name, subheading: "…", fields: [ [ "Tags", "Bowl" ] ],
  #                      actions: [ { label: "Open", url: "/recipes/#{r.id}" } ] } }
  #       end
  #     end
  #
  # The command palette calls it same-origin from the page (no cross-app
  # calls: each app searches only itself).
  #
  # Results are ordered by the app (most relevant / most recent first) and
  # capped at limit (default 5, max 20); queries are squished and capped at
  # 100 characters.
  #
  # One result:
  #   kind     "Transaction", "Recipe", … (shown as a chip)
  #   title    one line
  #   meta     one short plain-text line (dates, amounts)
  #   url      the record's page, a same-origin path ("/recipes/12")
  #   preview  { heading, subheading, amount ("−$212.48"), amount_tone
  #              ("negative" | "positive" | nil), fields: [[label, value], …],
  #              actions: [{ label, url }] } — all optional
  # Everything is plain text; the palette escapes it.
  module Search
    MIN_QUERY = 2
    MAX_QUERY = 100
    DEFAULT_LIMIT = 5
    MAX_LIMIT = 20
    TEXT_LIMIT = 200

    class << self
      # The query as searched, or nil when too short.
      def clean_query(raw)
        q = raw.to_s.squish[0, MAX_QUERY]
        q.length >= MIN_QUERY ? q : nil
      end

      def clean_limit(raw)
        n = raw.to_s.to_i
        n.positive? ? [ n, MAX_LIMIT ].min : DEFAULT_LIMIT
      end

      # This app's results, normalised. A failing search callable is reported
      # (Rails.error) and answers no results rather than a 500.
      def own(query, limit)
        callable = PersonalAppClient.config.search
        return [] unless callable

        normalize(callable.call(query, limit: limit)).first(limit)
      rescue StandardError => e
        ::Rails.error.report(e, handled: true, severity: :error) if defined?(::Rails) && ::Rails.respond_to?(:error)
        []
      end

      def normalize(results)
        Array(results).filter_map do |r|
          r = (r.respond_to?(:to_h) ? r.to_h : {}).transform_keys(&:to_s)
          next if r["title"].blank?

          {
            "kind" => text(r["kind"], 40), "title" => text(r["title"]), "meta" => text(r["meta"]),
            "url" => r["url"].to_s.presence, "preview" => normalize_preview(r["preview"])
          }.compact
        end
      end

      private

      def normalize_preview(p)
        return nil unless p.respond_to?(:to_h)

        p = p.to_h.transform_keys(&:to_s)
        tone = p["amount_tone"].to_s
        {
          "heading" => text(p["heading"]), "subheading" => text(p["subheading"]),
          "amount" => text(p["amount"], 40),
          "amount_tone" => (%w[negative positive].include?(tone) ? tone : nil),
          "fields" => Array(p["fields"]).filter_map { |f| a = Array(f); [ text(a[0], 40), text(a[1]) ] if a[0].present? }.first(8),
          "actions" => Array(p["actions"]).filter_map do |a|
            a = a.to_h.transform_keys(&:to_s)
            { "label" => text(a["label"], 40), "url" => a["url"].to_s } if a["label"].present? && a["url"].present?
          end.first(3)
        }.reject { |_, v| v.nil? || v == [] }
      end

      def text(v, max = TEXT_LIMIT)
        s = v.to_s.squish
        s.empty? ? nil : s.truncate(max)
      end

    end
  end
end
