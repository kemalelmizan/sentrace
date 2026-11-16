require "rails_helper"

RSpec.describe Sentrace do
  it "defines a gem version" do
    expect(Sentrace::VERSION).not_to be_nil
  end

  it "isolates the Rails engine namespace with sentrace_ table prefix" do
    expect(Sentrace::Engine.isolated?).to be(true)
    expect(Sentrace.table_name_prefix).to eq("sentrace_")
  end
end
