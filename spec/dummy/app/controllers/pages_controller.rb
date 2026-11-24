class PagesController < ApplicationController
  def home; end

  def settings; end

  def wide_form; end

  def boom
    raise NoMethodError, "undefined method 'frobnicate' for nil (item 42)"
  end

  def rendered_500
    render json: { error: "nope" }, status: 500
  end

  def flash_demo
    flash.now[:notice] = "Saved"
    flash.now[:alert] = "Careful"
    render :home
  end

  def missing
    raise ActiveRecord::RecordNotFound, "Couldn't find Item"
  end
end
