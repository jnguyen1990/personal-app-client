require "nokogiri"

# PLAT-07: the server-rendered twin of shared-core's dsFieldErrors.
RSpec.describe "personal_app_field_error / personal_app_field_aria" do
  recipe_class = Class.new do
    include ActiveModel::Model
    attr_accessor :title, :servings
    validates :title, presence: true
    validates :servings, numericality: { greater_than: 0 }
    def self.model_name = ActiveModel::Name.new(self, nil, "Recipe")
  end

  let(:view) { Class.new(ActionView::Base) { include PersonalAppClient::ShellHelper }.empty }
  let(:recipe) { recipe_class.new(title: "", servings: 0).tap(&:valid?) }

  it "describes an invalid field by the id of its message" do
    expect(view.personal_app_field_aria(recipe, :title)).to eq("aria-invalid": "true", "aria-describedby": "recipe_title_error")
    p = Nokogiri::HTML.fragment(view.personal_app_field_error(recipe, :title)).at("p")
    expect(p["class"]).to eq("form-error")
    expect(p["id"]).to eq("recipe_title_error")
    expect(p.text).to eq("Title can't be blank")
  end

  it "renders nothing for a valid field" do
    ok = recipe_class.new(title: "Soup", servings: 2).tap(&:valid?)
    expect(view.personal_app_field_aria(ok, :title)).to eq({})
    expect(view.personal_app_field_error(ok, :title)).to be_nil
  end

  it "has a partial for templates that prefer render" do
    html = ActionController::Base.render(partial: "personal_app/field_error", locals: { object: recipe, attribute: :servings })
    expect(html).to include('id="recipe_servings_error"', "Servings must be greater than 0")
  end
end
