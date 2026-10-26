defmodule WallopWeb.ProofLiveTest do
  use WallopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WallopCore.TestHelpers
  import WallopWeb.RateLimitHelpers
  import WallopWeb.SignedEntropyHelpers

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Weather.Schedule
  alias WallopWeb.Components.EntryCheck
  alias WallopWeb.Components.VerifyBlock
  alias WallopWeb.Plugs.SelfCheckRateLimit
  alias WallopWeb.RateLimiter

  describe "completed draw (static controller)" do
    test "renders completed draw with verification badge", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      conn = get(conn, "/proof/#{draw.id}")
      html = html_response(conn, 200)

      assert html =~ "Verified by Wallop"
    end

    test "renders download proof bundle button", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      conn = get(conn, "/proof/#{draw.id}")
      html = html_response(conn, 200)

      assert html =~ "Download proof bundle (JSON)"
      assert html =~ "/proof/#{draw.id}.json"
    end

    test "renders verify block with receipt data attributes", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      conn = get(conn, "/proof/#{draw.id}")
      html = html_response(conn, 200)

      assert html =~ "data-lock-receipt-jcs"
      assert html =~ "data-lock-signature-hex"
      assert html =~ "data-operator-public-key-hex"
      assert html =~ "data-execution-receipt-jcs"
      assert html =~ "data-execution-signature-hex"
      assert html =~ "data-infra-public-key-hex"
    end

    test "renders verifier mode badge and disclosure text", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      conn = get(conn, "/proof/#{draw.id}")
      html = html_response(conn, 200)

      # The browser gate runs in attestable mode: keys come from the
      # site's own key endpoints, not the bundle, and are not pinned.
      # The disclosure must say so plainly.
      assert html =~ "Mode: checked against published keys"
      refute html =~ "Mode: local self-check only"

      # The §4.2.4 caveat must be honestly disclosed: the browser-side
      # check trusts the keys this site serves, so a copied page with
      # swapped proof and keys would pass it, and the user is pointed at
      # the CLI as the tier-1 path.
      assert String.replace(html, ~r/\s+/, " ") =~
               "if someone copied this page and swapped in their own proof and keys"

      assert html =~ "Nothing is sent to us."
      refute html =~ "No server involved"
      assert html =~ "What does this verify?"
      assert html =~ "wallop-verify --mode attributable"
    end

    test "points the verify block at the published bundle and key endpoints", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)
      slug = operator_slug(draw)

      html = conn |> get("/proof/#{draw.id}") |> html_response(200)

      assert_verify_urls(html, draw, slug)
    end

    test "the published URLs the verify block names actually serve the bundle and keys",
         %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      html = conn |> get("/proof/#{draw.id}") |> html_response(200)
      [bundle_url] = attr_values(html, "data-bundle-url")
      [op_url] = attr_values(html, "data-operator-keys-url")
      [infra_url] = attr_values(html, "data-infra-keys-url")

      bundle = build_conn() |> get(bundle_url) |> response(200)
      assert {:ok, %{"lock_receipt" => _, "execution_receipt" => _}} = Jason.decode(bundle)

      for url <- [op_url, infra_url] do
        assert %{"keys" => [_ | _] = keys} = build_conn() |> get(url) |> json_response(200)

        for key <- keys do
          assert Map.keys(key) |> Enum.sort() ==
                   ~w(inserted_at key_class key_id public_key_hex)
        end
      end
    end

    test "a draw whose proof chain is incomplete still names the published proof, " <>
           "and the site refuses it",
         %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      # Receipts are append-only; step round the trigger for this one row,
      # inside the test's own transaction, as the sandbox migration does.
      WallopCore.Repo.query!("SET LOCAL session_replication_role = 'replica'")

      WallopCore.Repo.query!(
        "DELETE FROM execution_receipts WHERE draw_id = $1",
        [Ecto.UUID.dump!(draw.id)]
      )

      WallopCore.Repo.query!("SET LOCAL session_replication_role = 'origin'")

      html = conn |> get("/proof/#{draw.id}") |> html_response(200)

      # The page has partial receipts: a lock receipt, no execution receipt.
      assert attr_values(html, "data-lock-receipt-jcs") != []
      assert attr_values(html, "data-execution-receipt-jcs") == []

      # It still names the bundle and both key lists, so the browser check
      # (which fetches whenever there is any receipt data) asks for them.
      assert_verify_urls(html, draw, operator_slug(draw))

      # The site refuses the bundle. The browser check shows its red
      # "couldn't produce a complete proof" for a refused bundle; that
      # branch is covered in assets/test/verify_core_test.mjs.
      assert %{"error" => "proof_chain_incomplete"} =
               build_conn() |> get("/proof/#{draw.id}/json") |> json_response(500)
    end

    test "sets immutable cache headers", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      conn = get(conn, "/proof/#{draw.id}")

      assert get_resp_header(conn, "cache-control") == [
               "public, max-age=31536000, immutable"
             ]
    end

    test "shows proof chain with entry hash, seed, and algorithm link", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      conn = get(conn, "/proof/#{draw.id}")
      html = html_response(conn, 200)

      assert html =~ draw.entry_hash
      assert html =~ draw.seed
      assert html =~ "fair_pick"
    end
  end

  describe "observation-weather draws" do
    test "a draw awaiting entropy shows when the result is due, and counts down to it", %{
      conn: conn
    } do
      {_operator, api_key} = create_v6_operator()
      round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), 3 * 3600))
      wt = Schedule.weather_time_for_round(round)
      # The row's weather_time is another hour: the page follows the signed receipt.
      draw = put_v6_awaiting!(open_draw_with_entries(api_key), DateTime.add(wt, -3600), round)
      due = Quicknet.pub_time(round)

      {:ok, _view, html} = live(conn, "/live/proof/#{draw.id}")

      assert html =~
               "Result due at #{Calendar.strftime(due, "%H:%M:%S UTC on %d %b %Y")}, " <>
                 "when drand publishes its random number for this draw"

      assert attr_values(html, "data-target") == [DateTime.to_iso8601(due)]
      refute html =~ "Entropy available in"
      assert html =~ "Result due in"

      assert html =~
               "drand round ##{round}, Middle Wallop&#39;s #{Calendar.strftime(wt, "%H:%M UTC")} " <>
                 "weather reading, if it turns up. The result is due at " <>
                 Calendar.strftime(due, "%H:%M:%S UTC")
    end

    test "a forecast draw awaiting entropy is as before", %{conn: conn} do
      draw = create_draw(create_api_key(), %{})

      {:ok, _view, html} = live(conn, "/live/proof/#{draw.id}")

      assert html =~ "weather at #{Calendar.strftime(draw.weather_time, "%H:%M UTC")}"
      assert html =~ "Entropy available in"
      assert attr_values(html, "data-target") == [DateTime.to_iso8601(draw.weather_time)]
      refute html =~ "Result due"
      refute html =~ "Middle Wallop"
    end

    test "state (a): Middle Wallop's reading, as the signed receipt says", %{conn: conn} do
      draw = completed_signed!(:observed)
      html = conn |> get("/proof/#{draw.id}") |> html_response(200) |> squash()

      assert html =~ "Set by the draw's drand round, so nobody gets to pick it"
      assert html =~ "The signed receipt says:"
      assert html =~ "Middle Wallop (WMO 03749) reported this at "
      assert html =~ "141;1025;85;2432"
      assert html =~ "seed = SHA-256(JCS(entry_hash, drand_randomness, weather_value))"
      assert html =~ "drand round ##{draw.drand_round}. Declared: Middle Wallop&#39;s "
      assert html =~ "Fewer than drand&#39;s threshold of nodes collude."
      assert html =~ "The lock time (locked_at) is wallop&#39;s clock."

      assert html =~
               "Checkable with wallop-verify weather-attest: the value matches the public record"

      refute html =~ "result due"
      assert html =~ "a random number from drand: "
      assert html =~ "Middle Wallop reported 141;1025;85;2432 at "
      refute html =~ "National Grid"
      refute html =~ "BMRS"
      refute html =~ "drand did this one on its own"
    end

    test "state (b): the grid frequency, with the attribution and what you're trusting", %{
      conn: conn
    } do
      draw = completed_signed!(:frequency)
      html = conn |> get("/proof/#{draw.id}") |> html_response(200) |> squash()
      year = Schedule.weather_time_for_round(draw.drand_round).year

      assert html =~ "The signed receipt says:"

      assert html =~
               "Middle Wallop&#39;s reading was running late, so this draw listened to the hum " <>
                 "of the National Grid instead."

      assert html =~ "50012;50018;50012;49983;49980;49953;49912;49883"
      assert html =~ "seed = SHA-256(JCS(entry_hash, drand_randomness, freq_value))"
      assert html =~ "Contains BMRS data © Elexon Limited copyright and database right #{year}"
      assert html =~ "What you're trusting here:"

      assert html =~
               "On a fallback to the grid frequency, Elexon published what the grid actually " <>
                 "did, and does not revise readings"

      assert html =~ "matches Elexon&#39;s readings for T…T+105s"
      assert html =~ "can&#39;t tell a late reading from a withheld one."
      assert html =~ "A private or amateur sensor beside the airfield could narrow it further"
      assert html =~ "the National Grid&#39;s hum instead of the weather"
      refute html =~ "reported this at"
      refute html =~ "weather_value))"
    end

    test "state (c): drand alone", %{conn: conn} do
      draw = completed_signed!(:fallback)
      html = conn |> get("/proof/#{draw.id}") |> html_response(200) |> squash()

      assert html =~
               "Middle Wallop was late and the Grid went quiet, so drand did this one on its own."

      assert html =~ "seed = SHA-256(JCS(entry_hash, drand_randomness))"
      assert html =~ "drand alone, no weather or Grid"

      assert html =~
               "A reading can arrive after the deadline, so a fallback can happen for an hour"

      assert html =~ "can&#39;t tell a late reading from a withheld one."
      refute html =~ "BMRS"
      refute html =~ "reported this at"
    end

    test "a receipt outside the three states gets no source and says so", %{conn: conn} do
      # State (a) plus a freq_value: the row still holds a weather value.
      draw =
        completed_signed!(:observed, fn signed ->
          Map.put(signed, "freq_value", "50012;50018;50012;49983;49980;49953;49912;49883")
        end)

      html = conn |> get("/proof/#{draw.id}") |> html_response(200) |> squash()

      assert html =~
               "This draw&#39;s signed receipt doesn&#39;t match any of the three ways a weather " <>
                 "draw can go (Middle Wallop, the Grid, or drand alone), so there&#39;s no weather " <>
                 "source to show, and we can&#39;t vouch for it."

      refute html =~ "The signed receipt says:"
      refute html =~ "reported this at"
      refute html =~ "National Grid"
      refute html =~ "drand did this one on its own"
      refute html =~ "seed = SHA-256"
      refute html =~ "BMRS"
      # The page still hands the browser check the receipt it must refuse.
      assert html =~ "data-execution-receipt-jcs"
    end
  end

  describe "grid-frequency draws" do
    test "readings: the frequency formula, the readings, its trust lines and BMRS", %{conn: conn} do
      draw = completed_signed!({:freq, :observed})
      html = conn |> get("/proof/#{draw.id}") |> html_response(200) |> squash()

      assert html =~ "seed = SHA-256(JCS(entry_hash, drand_randomness, freq_value))"
      refute html =~ "seed = SHA-256(JCS(entry_hash, drand_randomness))"
      assert html =~ "50012;50018;50012;49983;49980;49953;49912;49883"
      assert html =~ "Contains BMRS data © Elexon Limited copyright and database right"

      assert html =~
               "Elexon published what the grid actually did, and doesn&#39;t revise readings."

      assert html =~ "the National Grid&#39;s hum"
      assert html =~ "wallop&#39;s clock recorded the close time honestly."
      assert html =~ "Declared: the National Grid&#39;s frequency from "
      refute html =~ "Middle Wallop"
    end

    test "no readings: drand alone", %{conn: conn} do
      draw = completed_signed!({:freq, :fallback})
      html = conn |> get("/proof/#{draw.id}") |> html_response(200) |> squash()

      assert html =~ "The Grid went quiet, so drand did this one on its own."
      assert html =~ "seed = SHA-256(JCS(entry_hash, drand_randomness))"
      assert html =~ "drand alone, no Grid"
      refute html =~ "BMRS"
    end

    test "a receipt outside its two states gets no source", %{conn: conn} do
      draw =
        completed_signed!({:freq, :observed}, fn signed ->
          Map.put(signed, "freq_fallback_reason", "no_frequency_by_deadline")
        end)

      html = conn |> get("/proof/#{draw.id}") |> html_response(200) |> squash()

      assert html =~
               "doesn&#39;t match either of the two ways a grid-frequency draw can go (the Grid, or drand alone)"

      refute html =~ "seed = SHA-256"
      refute html =~ "BMRS"
      refute html =~ "drand did this one on its own"
    end
  end

  describe "verify block component" do
    test "results JSON is in position order, as in the proof bundle" do
      results = [
        %{"entry_id" => "b", "position" => 2},
        %{"entry_id" => "c", "position" => 3},
        %{"entry_id" => "a", "position" => 1}
      ]

      assert VerifyBlock.results_json(results) ==
               ~s([{"entry_id":"a","position":1},{"entry_id":"b","position":2},{"entry_id":"c","position":3}])

      assert VerifyBlock.results_json(nil) == "[]"
    end

    test "names the published bundle and key endpoints when the draw has receipts" do
      draw = component_draw("d1d1d1d1-0000-4000-8000-000000000001")

      html =
        render_component(&VerifyBlock.verify_block/1,
          draw: draw,
          entries_json: "[]",
          results_json: "[]",
          receipt: %{payload_jcs: "{}", signature: <<1>>},
          operator_public_key_hex: String.duplicate("ab", 32),
          operator_slug: "acme"
        )

      assert_verify_urls(html, draw, "acme")
    end

    test "names no operator keys endpoint for a draw without a lock receipt" do
      draw = component_draw("d1d1d1d1-0000-4000-8000-000000000002")

      html =
        render_component(&VerifyBlock.verify_block/1,
          draw: draw,
          entries_json: "[]",
          results_json: "[]",
          operator_slug: "acme"
        )

      assert attr_values(html, "data-operator-keys-url") == []
      assert attr_values(html, "data-bundle-url") == ["/proof/#{draw.id}/json"]
    end
  end

  describe "entry check (static controller)" do
    test "finds a winning entry via query param", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      winning_id = List.first(draw.results)["entry_id"]

      conn = get(conn, "/proof/#{draw.id}?entry_id=#{winning_id}")
      html = html_response(conn, 200)

      assert html =~ "in the winner list"
    end

    test "reports not found for unknown entry", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      _draw = execute_draw(draw, test_seed(), api_key)

      unknown_uuid = "00000000-0000-4000-8000-000000000000"
      conn = get(conn, "/proof/#{draw.id}?entry_id=#{unknown_uuid}")
      html = html_response(conn, 200)

      assert html =~ "Not a winner this time"
    end
  end

  describe "direct entry check link" do
    test "auto-checks a winning entry via path", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      winning_id = List.first(draw.results)["entry_id"]

      conn = get(conn, "/proof/#{draw.id}/#{winning_id}")
      html = html_response(conn, 200)

      assert html =~ "in the winner list"
    end

    test "auto-checks a non-winning entry via path", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      winning_uuids = Enum.map(draw.results, & &1["entry_id"])
      all_uuids = Enum.map(WallopCore.Entries.load_for_draw(draw.id), & &1.uuid)
      losing_uuid = Enum.find(all_uuids, fn u -> u not in winning_uuids end)

      conn = get(conn, "/proof/#{draw.id}/#{losing_uuid}")
      html = html_response(conn, 200)

      assert html =~ "Not a winner this time"
    end

    test "pre-fills the entry ID input", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      winning_id = List.first(draw.results)["entry_id"]

      conn = get(conn, "/proof/#{draw.id}/#{winning_id}")
      html = html_response(conn, 200)

      assert html =~ "value=\"#{winning_id}\""
    end
  end

  describe "check_url passthrough on the static proof page" do
    test "renders the operator's check_url when a non-winner is checked", %{conn: conn} do
      api_key = create_api_key()

      draw =
        create_draw(api_key, %{
          check_url: "https://operator.example/check-your-ticket"
        })

      draw = execute_draw(draw, test_seed(), api_key)

      winning_uuids = Enum.map(draw.results, & &1["entry_id"])
      all_uuids = Enum.map(WallopCore.Entries.load_for_draw(draw.id), & &1.uuid)
      losing_uuid = Enum.find(all_uuids, fn u -> u not in winning_uuids end)

      conn = get(conn, "/proof/#{draw.id}/#{losing_uuid}")
      html = html_response(conn, 200)

      assert html =~ "Not a winner this time"
      assert html =~ "https://operator.example/check-your-ticket"
      assert html =~ ~s|rel="noopener noreferrer"|
      assert html =~ ~s|target="_blank"|
    end

    test "does not render check_url when draw has none", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      winning_uuids = Enum.map(draw.results, & &1["entry_id"])
      all_uuids = Enum.map(WallopCore.Entries.load_for_draw(draw.id), & &1.uuid)
      losing_uuid = Enum.find(all_uuids, fn u -> u not in winning_uuids end)

      conn = get(conn, "/proof/#{draw.id}/#{losing_uuid}")
      html = html_response(conn, 200)

      assert html =~ "Not a winner this time"
      refute html =~ "check-your-ticket"
      refute html =~ "ticket-check page"
    end

    test "does not render check_url on winner response", %{conn: conn} do
      api_key = create_api_key()

      draw =
        create_draw(api_key, %{
          check_url: "https://operator.example/check"
        })

      draw = execute_draw(draw, test_seed(), api_key)

      winning_id = List.first(draw.results)["entry_id"]
      conn = get(conn, "/proof/#{draw.id}/#{winning_id}")
      html = html_response(conn, 200)

      assert html =~ "in the winner list"
      # check_url is a fallback for non-winners — not shown for winners
      refute html =~ "https://operator.example/check"
    end
  end

  describe "in-progress draw (LiveView redirect)" do
    test "redirects to LiveView for in-progress draw", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})

      conn = get(conn, "/proof/#{draw.id}")

      assert redirected_to(conn) =~ "/live/proof/#{draw.id}"
    end

    test "renders timeline in LiveView", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})

      {:ok, _view, html} = live(conn, "/live/proof/#{draw.id}")

      assert html =~ "Entries Locked"
      assert html =~ "Entropy Declared"
    end
  end

  describe "failed draw (static controller)" do
    test "renders failed draw with failure reason", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      {:ok, failed_draw} =
        draw
        |> Ash.Changeset.for_update(:mark_failed, %{failure_reason: "entropy timeout"},
          authorize?: false
        )
        |> Ash.update(domain: WallopCore.Domain, authorize?: false)

      conn = get(conn, "/proof/#{failed_draw.id}")
      html = html_response(conn, 200)

      assert html =~ "entropy timeout"
    end
  end

  describe "open draw (LiveView redirect)" do
    test "redirects open draw to LiveView", %{conn: conn} do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      conn = get(conn, "/proof/#{draw.id}")

      assert redirected_to(conn) =~ "/live/proof/#{draw.id}"
    end

    test "LiveView mounts and renders without crashing for an :open draw", %{conn: conn} do
      # Regression: ProofPreLockView ships only a 9-field allowlist
      # (id, name, status, winner_count, entry_count, opened_at,
      # check_url, operator_sequence, operator). Components that
      # render the :open branch must NOT bind to fields outside that
      # set. Specifically: the timeline component used in :open must
      # not try to read stage_timestamps, entry_hash, drand_round,
      # weather_time, etc. — none of those exist on the pre-lock view.
      #
      # The pre-existing "redirects open draw to LiveView" test above
      # only verified the HTTP redirect; it did not actually mount
      # the LiveView. This one does.
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      {:ok, _view, html} = live(conn, "/live/proof/#{draw.id}")

      assert html =~ "Draw Open"
      # Every step in the timeline must render. If a downstream
      # component reaches into a field outside the pre-lock allowlist,
      # the live mount itself raises and this assertion never runs.
      assert html =~ "Entries Open"
      assert html =~ "Entries Locked"
      assert html =~ "Entropy Declared"
      assert html =~ "Fetching Entropy"
      assert html =~ "Computing Seed"
      assert html =~ "Winners Selected"
    end

    test "LiveView render is stable under PubSub update on an :open draw", %{conn: conn} do
      # Symmetric guard for the handle_info path: when a PubSub
      # broadcast arrives for an :open draw and the status is still
      # :open afterwards, the re-render must not raise. Catches the
      # case where `open_view_for/2` falls back to the full Draw
      # struct or vice versa.
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      {:ok, view, _html} = live(conn, "/live/proof/#{draw.id}")

      Phoenix.PubSub.broadcast(WallopCore.PubSub, "draw:#{draw.id}", {:draw_updated, draw})

      assert render(view) =~ "Draw Open"
    end
  end

  describe "self-check rate limit on the live page" do
    setup do
      RateLimiter.reset()
      await_fresh_window()
      :ok
    end

    test "counts against the client address from the HTTP render, sharing the plug's bucket",
         %{conn: conn} do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      cap = SelfCheckRateLimit.max_attempts()
      client = "198.51.100.7"
      other = "198.51.100.8"

      for _ <- 1..(cap - 1), do: :ok = SelfCheckRateLimit.check_rate(client)

      {:ok, view, _html} = live(%{conn | remote_ip: {198, 51, 100, 7}}, "/live/proof/#{draw.id}")

      # The live check takes the last token in the client's bucket...
      render_hook(view, "check_entry", %{"entry_id" => Ecto.UUID.generate()})
      assert SelfCheckRateLimit.check_rate(client) == :rate_limited

      # ...and further checks say they were refused, not that the entry lost.
      html = render_hook(view, "check_entry", %{"entry_id" => Ecto.UUID.generate()})
      refute html =~ "is a winner"
      refute html =~ "Not a winner this time"
      assert html =~ "Too many checks from your connection"

      # Neither the proxy bucket ("unknown") nor another client was touched.
      assert SelfCheckRateLimit.check_rate(other) == :ok
      assert SelfCheckRateLimit.check_rate("unknown") == :ok
    end
  end

  describe "rate-limited check" do
    setup do
      RateLimiter.reset()
      await_fresh_window()
      :ok
    end

    defp open_draw do
      WallopCore.Resources.Draw
      |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: create_api_key())
      |> Ash.create!()
    end

    test "the entry check says so instead of calling a real winner a loser" do
      api_key = create_api_key()
      draw = execute_draw(create_draw(api_key, %{}), test_seed(), api_key)
      winning_id = List.first(draw.results)["entry_id"]

      # A completed draw, a check result from a refused (rate-limited) lookup.
      html =
        render_component(&EntryCheck.entry_check/1,
          check_result: %{rate_limited: true},
          draw_status: draw.status,
          checked_entry_id: winning_id,
          check_url: nil
        )

      refute html =~ "Not a winner this time"
      refute html =~ "in the winner list."
      assert html =~ "Too many checks from your connection"
    end

    test "a refused live check on the page says it was refused", %{conn: conn} do
      draw = open_draw()
      {:ok, view, _html} = live(%{conn | remote_ip: {198, 51, 100, 9}}, "/live/proof/#{draw.id}")

      for _ <- 1..SelfCheckRateLimit.max_attempts(),
          do: SelfCheckRateLimit.check_rate("198.51.100.9")

      html = render_hook(view, "check_entry", %{"entry_id" => Ecto.UUID.generate()})

      refute html =~ "Not a winner this time"
      assert html =~ "Too many checks from your connection"
    end

    test "an IPv6 client and a sibling in the same /64 share the self-check budget",
         %{conn: conn} do
      draw = open_draw()

      {:ok, view, _html} =
        live(%{conn | remote_ip: {0x2001, 0xDB8, 1, 2, 0, 0, 0, 1}}, "/live/proof/#{draw.id}")

      sibling = RateLimiter.ip_bucket({0x2001, 0xDB8, 1, 2, 0xFFFF, 0, 0, 9})

      for _ <- 1..SelfCheckRateLimit.max_attempts(), do: SelfCheckRateLimit.check_rate(sibling)

      html = render_hook(view, "check_entry", %{"entry_id" => Ecto.UUID.generate()})
      assert html =~ "Too many checks from your connection"
    end
  end

  describe "nonexistent draw" do
    test "redirects for nonexistent draw", %{conn: conn} do
      conn = get(conn, "/proof/00000000-0000-0000-0000-000000000000")

      assert redirected_to(conn) == "/"
    end
  end

  describe "PubSub updates (LiveView)" do
    test "re-renders when draw is updated via PubSub", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})

      {:ok, view, html} = live(conn, "/live/proof/#{draw.id}")

      refute html =~ "Verified by Wallop"

      completed_draw = execute_draw(draw, test_seed(), api_key)

      Phoenix.PubSub.broadcast(
        WallopCore.PubSub,
        "draw:#{draw.id}",
        {:draw_updated, completed_draw}
      )

      html = render(view)
      assert html =~ "Verifying..."

      assert {:error, {:live_redirect, %{to: path}}} = render_click(view, "reveal_complete")
      assert path == "/proof/#{draw.id}"
    end

    test "ignores PubSub update for different draw", %{conn: conn} do
      api_key = create_api_key()
      draw_a = create_draw(api_key, %{})
      draw_b = create_draw(api_key, %{})

      {:ok, view, html} = live(conn, "/live/proof/#{draw_a.id}")
      refute html =~ "Verified by Wallop"

      completed_draw_b = execute_draw(draw_b, test_seed(), api_key)

      Phoenix.PubSub.broadcast(
        WallopCore.PubSub,
        "draw:#{draw_a.id}",
        {:draw_updated, completed_draw_b}
      )

      html = render(view)
      refute html =~ "Verified by Wallop"
    end

    test "updates draw when status hasn't changed", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})

      {:ok, view, _html} = live(conn, "/live/proof/#{draw.id}")

      Phoenix.PubSub.broadcast(
        WallopCore.PubSub,
        "draw:#{draw.id}",
        {:draw_updated, draw}
      )

      html = render(view)
      assert html =~ "Entries Locked"
    end
  end

  defp squash(html), do: String.replace(html, ~r/\s+/, " ")

  defp operator_slug(draw) do
    Ash.get!(WallopCore.Resources.Operator, draw.operator_id, authorize?: false).slug
  end

  defp attr_values(html, attr) do
    Regex.scan(~r/#{attr}="([^"]*)"/, html, capture: :all_but_first) |> List.flatten()
  end

  defp assert_verify_urls(html, draw, slug) do
    assert attr_values(html, "data-bundle-url") == ["/proof/#{draw.id}/json"]
    assert attr_values(html, "data-operator-keys-url") == ["/operator/#{slug}/keys"]
    assert attr_values(html, "data-infra-keys-url") == ["/infrastructure/keys"]
  end

  defp component_draw(id) do
    %{
      id: id,
      entry_count: 0,
      entry_hash: nil,
      seed: nil,
      drand_round: nil,
      drand_randomness: nil,
      weather_value: nil,
      results: []
    }
  end
end
