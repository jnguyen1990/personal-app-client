module PersonalAppClient
  # GET /api/search?q=&limit= — this app's own results (config.search,
  # PersonalAppClient::Search), for the command palette on its own pages.
  # Auth is the app's Api::BaseController (same-origin from the browser,
  # behind Cloudflare Access). A query shorter than two characters answers 422.
  class SearchController < PersonalAppClient.api_base_controller
    def index
      query = PersonalAppClient::Search.clean_query(params[:q])
      unless query
        return render json: { error: "q must be at least #{PersonalAppClient::Search::MIN_QUERY} characters" },
                      status: :unprocessable_entity
      end

      limit = PersonalAppClient::Search.clean_limit(params[:limit])
      render json: { app: PersonalAppClient.config.app_id, query: query,
                     results: PersonalAppClient::Search.own(query, limit) }
    end
  end
end
