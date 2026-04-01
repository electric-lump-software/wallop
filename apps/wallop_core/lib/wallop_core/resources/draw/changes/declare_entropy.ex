defmodule WallopCore.Resources.Draw.Changes.DeclareEntropy do
  @moduledoc """
  Declares entropy sources at draw creation time.

  This change:
  1. Computes a future drand round (~30 seconds from now)
  2. Sets weather_time to 10 minutes from now
  3. Sets weather_station to "middle-wallop" (51.1494, -1.5714)
  4. Sets drand_chain to the quicknet chain hash
  5. Sets status to :awaiting_entropy
  6. Schedules an EntropyWorker job for the weather_time
  """
  use Ash.Resource.Change

  alias WallopCore.Entropy.{DrandClient, EntropyWorker}

  # drand quicknet parameters
  @quicknet_genesis 1_692_803_367
  @quicknet_period 3
  @round_buffer 10

  @weather_station "middle-wallop"

  @impl true
  def change(changeset, _opts, _context) do
    declare_entropy(changeset)
  end

  defp declare_entropy(changeset) do
    changeset
    |> set_entropy_fields()
    |> schedule_entropy_worker()
  end

  defp set_entropy_fields(changeset) do
    if changeset.errors != [] do
      changeset
    else
      future_round = compute_future_drand_round()
      weather_time = jittered_weather_time()

      changeset
      |> Ash.Changeset.force_change_attribute(:drand_chain, DrandClient.quicknet_chain_hash())
      |> Ash.Changeset.force_change_attribute(:drand_round, future_round)
      |> Ash.Changeset.force_change_attribute(:weather_station, @weather_station)
      |> Ash.Changeset.force_change_attribute(:weather_time, weather_time)
      |> Ash.Changeset.force_change_attribute(:status, :awaiting_entropy)
    end
  end

  defp schedule_entropy_worker(changeset) do
    if changeset.errors != [] do
      changeset
    else
      Ash.Changeset.after_action(changeset, fn _changeset, draw ->
        %{draw_id: draw.id}
        |> EntropyWorker.new(scheduled_at: draw.weather_time)
        |> Oban.insert()

        Phoenix.PubSub.broadcast(WallopCore.PubSub, "draw:#{draw.id}", {:draw_updated, draw})
        {:ok, draw}
      end)
    end
  end

  defp compute_future_drand_round do
    now = System.os_time(:second)
    current_round = div(now - @quicknet_genesis, @quicknet_period) + 1
    current_round + @round_buffer
  end

  defp jittered_weather_time do
    # 3-5 minutes from now (jittered to avoid thundering herd)
    delay = Enum.random(180..300)

    DateTime.utc_now()
    |> DateTime.add(delay, :second)
    |> DateTime.truncate(:second)
  end
end
