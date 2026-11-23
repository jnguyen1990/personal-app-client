require "active_support/core_ext/object/blank"

module PersonalAppClient
  # The sidebar's nav items, from `config.nav_items`. Plain Ruby so the
  # active-state rules are testable without a view.
  #
  #     { path: "/",      label: "today", ico: "star",   key: "1" }                       # exact
  #     { path: "/goals", label: "goals", ico: "target", key: "2", active: :prefix }
  #     { path: "/",      label: "today", ico: "star",   key: "1", prefixes: %w[/plan] }   # "/" or /plan…
  #     { path: "/x",     label: "x",     ico: "grid",   key: "3", active: %r{\A/x(/|\z)} }
  #     { path: "/y",     label: "y",     ico: "grid",   key: "4", active: ->(path) { … } }
  #
  # `tab:` picks the mobile tab bar's items (see .tabs): `tab: true` on the
  # ones that should be tabs, `tab: false` to keep one out of the default
  # first four.
  module Nav
    Item = Struct.new(:path, :label, :ico, :key, :active, :tab, keyword_init: true) do
      def active?
        active ? true : false
      end

      # The ⌘ hint: "⌘1" … "⌘9", "⌘," — nil when the item has no key.
      def kbd
        key.present? ? "⌘#{key}" : nil
      end
    end

    module_function

    def items(specs, request_path)
      Array(specs).map { |spec| item(spec, request_path) }
    end

    # The mobile tab bar's items: the ones marked `tab: true` when any is,
    # otherwise the first `count` that are not `tab: false`. At most `count`
    # either way (the bar has room for four plus "More").
    def tabs(items, count = 4)
      items = Array(items)
      marked = items.select { |i| i.tab == true }
      (marked.any? ? marked : items.reject { |i| i.tab == false }).first(count)
    end

    def item(spec, request_path)
      spec = spec.to_h.transform_keys(&:to_sym)
      path = spec.fetch(:path).to_s
      Item.new(path: path, label: spec[:label].to_s, ico: spec[:ico].to_s,
               key: spec[:key]&.to_s, active: active?(spec, path, request_path.to_s),
               tab: spec.key?(:tab) ? (spec[:tab] ? true : false) : nil)
    end

    def active?(spec, path, request_path)
      rule = spec.key?(:active) ? spec[:active] : :exact
      return true if Array(spec[:prefixes]).any? { |prefix| request_path.start_with?(prefix.to_s) }

      case rule
      when :exact, nil then request_path == path
      when :prefix then request_path.start_with?(path)
      when Regexp then rule.match?(request_path)
      when Proc then rule.arity.zero? ? rule.call : rule.call(request_path)
      when true, false then rule
      else
        raise ArgumentError, "nav item #{path.inspect}: active must be :exact, :prefix, a Regexp or a Proc"
      end
    end
  end
end
