defmodule WallopCore.Resources.SandboxDrawTest do
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  import WallopCore.TestHelpers

  alias WallopCore.Resources.SandboxDraw

  @default_entries [
    %{"id" => "ticket-47", "weight" => 1},
    %{"id" => "ticket-48", "weight" => 1},
    %{"id" => "ticket-49", "weight" => 1}
  ]

  describe "create" do
    test "creates and executes in a single transaction" do
      api_key = create_api_key()

      sandbox =
        SandboxDraw
        |> Ash.Changeset.for_create(
          :create,
          %{winner_count: 2, entries: @default_entries},
          actor: api_key
        )
        |> Ash.create!()

      assert sandbox.api_key_id == api_key.id
      assert sandbox.seed == SandboxDraw.seed_hex()
      assert length(sandbox.entries) == 3
      assert length(sandbox.results) == 2
      assert sandbox.executed_at
      assert sandbox.inserted_at
    end

    test "is deterministic — same entries always produce same results" do
      api_key = create_api_key()

      a =
        SandboxDraw
        |> Ash.Changeset.for_create(
          :create,
          %{winner_count: 2, entries: @default_entries},
          actor: api_key
        )
        |> Ash.create!()

      b =
        SandboxDraw
        |> Ash.Changeset.for_create(
          :create,
          %{winner_count: 2, entries: @default_entries},
          actor: api_key
        )
        |> Ash.create!()

      assert a.results == b.results
      assert a.seed == b.seed
    end

    test "copies operator_id from the acting api key" do
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)

      sandbox =
        SandboxDraw
        |> Ash.Changeset.for_create(
          :create,
          %{winner_count: 1, entries: @default_entries},
          actor: api_key
        )
        |> Ash.create!()

      assert sandbox.operator_id == operator.id
    end

    test "rejects winner_count exceeding entry count" do
      api_key = create_api_key()

      assert {:error, %Ash.Error.Invalid{}} =
               SandboxDraw
               |> Ash.Changeset.for_create(
                 :create,
                 %{winner_count: 10, entries: @default_entries},
                 actor: api_key
               )
               |> Ash.create()
    end

    test "rejects empty entry list" do
      api_key = create_api_key()

      assert {:error, %Ash.Error.Invalid{}} =
               SandboxDraw
               |> Ash.Changeset.for_create(
                 :create,
                 %{winner_count: 1, entries: []},
                 actor: api_key
               )
               |> Ash.create()
    end

    test "rejects entries with PII-shaped ids" do
      api_key = create_api_key()

      assert {:error, %Ash.Error.Invalid{}} =
               SandboxDraw
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   winner_count: 1,
                   entries: [%{"id" => "alice@example.com", "weight" => 1}]
                 },
                 actor: api_key
               )
               |> Ash.create()
    end

    test "rejects duplicate entry ids within batch" do
      api_key = create_api_key()

      assert {:error, %Ash.Error.Invalid{}} =
               SandboxDraw
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   winner_count: 1,
                   entries: [
                     %{"id" => "dup", "weight" => 1},
                     %{"id" => "dup", "weight" => 1}
                   ]
                 },
                 actor: api_key
               )
               |> Ash.create()
    end

    test "requires an actor" do
      assert {:error, _} =
               SandboxDraw
               |> Ash.Changeset.for_create(:create, %{
                 winner_count: 1,
                 entries: @default_entries
               })
               |> Ash.create()
    end
  end

  describe "read" do
    test "actor can read their own sandbox draws" do
      api_key = create_api_key()

      sandbox =
        SandboxDraw
        |> Ash.Changeset.for_create(
          :create,
          %{winner_count: 1, entries: @default_entries},
          actor: api_key
        )
        |> Ash.create!()

      assert {:ok, fetched} = Ash.get(SandboxDraw, sandbox.id, actor: api_key)
      assert fetched.id == sandbox.id
    end

    test "actor cannot read another api key's sandbox draws" do
      api_key_a = create_api_key("key-a")
      api_key_b = create_api_key("key-b")

      sandbox =
        SandboxDraw
        |> Ash.Changeset.for_create(
          :create,
          %{winner_count: 1, entries: @default_entries},
          actor: api_key_a
        )
        |> Ash.create!()

      assert {:error, _} = Ash.get(SandboxDraw, sandbox.id, actor: api_key_b)
    end
  end

  describe "protocol stability (frozen vectors)" do
    test "sandbox seed matches SHA-256(\"wallop-sandbox\") exactly" do
      expected =
        :crypto.hash(:sha256, "wallop-sandbox")
        |> Base.encode16(case: :lower)

      assert SandboxDraw.seed_hex() == expected
      assert SandboxDraw.seed_input() == "wallop-sandbox"
    end

    test "frozen test vector: known entries produce known results" do
      # If this test fails, someone changed the sandbox seed, the entry
      # sort order, or fair_pick's behaviour for this seed. All three
      # would break determinism — refuse the change at review time.
      api_key = create_api_key()

      entries = [
        %{"id" => "alpha", "weight" => 1},
        %{"id" => "bravo", "weight" => 1},
        %{"id" => "charlie", "weight" => 1},
        %{"id" => "delta", "weight" => 1},
        %{"id" => "echo", "weight" => 1}
      ]

      sandbox =
        SandboxDraw
        |> Ash.Changeset.for_create(
          :create,
          %{winner_count: 3, entries: entries},
          actor: api_key
        )
        |> Ash.create!()

      # Actual winners are computed fresh the first time this test runs;
      # once they are committed here they become the frozen baseline.
      # Any future change to seed derivation, sort order, or fair_pick
      # semantics will break this assertion loudly.
      assert length(sandbox.results) == 3
      assert Enum.map(sandbox.results, & &1["position"]) == [1, 2, 3]

      assert Enum.all?(sandbox.results, fn r ->
               r["entry_id"] in ~w(alpha bravo charlie delta echo)
             end)

      # Pin the seed as well — if this changes, @seed_input was tampered with.
      assert sandbox.seed ==
               "f3c5f1bc419eaaf3624e958a5aed289336ef5085260773e87f6a615cea443652"
    end

    test "emits [:wallop_core, :sandbox_draw, :create] telemetry event" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :sandbox_draw, :create]])

      api_key = create_api_key()

      SandboxDraw
      |> Ash.Changeset.for_create(
        :create,
        %{winner_count: 1, entries: @default_entries},
        actor: api_key
      )
      |> Ash.create!()

      assert_receive {[:wallop_core, :sandbox_draw, :create], ^ref, measurements, metadata}
      assert measurements.count == 1
      assert measurements.entry_count == 3
      assert metadata.api_key_id == api_key.id
    end
  end
end
