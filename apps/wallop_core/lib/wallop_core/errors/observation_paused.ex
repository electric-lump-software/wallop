defmodule WallopCore.Errors.ObservationPaused do
  @moduledoc """
  An observation-weather lock refused because the service that fetches
  Land Observations readings hasn't recently said it can fetch them. The
  draw stays open; a grid-frequency lock is unaffected.

  Its own `code` lets a client tell this refusal apart without reading the
  message. It is a 400.
  """

  use Splode.Error, class: :invalid, fields: []

  @message "observation-weather draws are paused here: Land Observations readings can't be fetched right now"

  @doc "The refusal's text, without the breadcrumbs `message/1` adds."
  def detail, do: @message

  def message(_error), do: @message

  defimpl AshJsonApi.ToJsonApiError do
    def to_json_api_error(_error) do
      %AshJsonApi.Error{
        id: Ash.UUID.generate(),
        status_code: 400,
        code: "observation_paused",
        title: "ObservationPaused",
        detail: @for.detail(),
        meta: %{}
      }
    end
  end
end
