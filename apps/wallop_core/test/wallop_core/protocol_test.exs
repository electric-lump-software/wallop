defmodule WallopCore.ProtocolTest do
  use ExUnit.Case, async: true

  alias WallopCore.Protocol

  @draw_id "11111111-1111-4111-8111-111111111111"
  @uuid_a "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @uuid_b "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @other_draw "22222222-2222-4222-8222-222222222222"

  describe "entry_hash/1 — happy path" do
    test "sorts entries by uuid and wraps in {draw_id, entries}" do
      entries = [
        %{uuid: @uuid_b, operator_ref: nil, weight: 2},
        %{uuid: @uuid_a, operator_ref: nil, weight: 1}
      ]

      expected_jcs =
        ~s({"draw_id":"#{@draw_id}","entries":[{"uuid":"#{@uuid_a}","weight":1},{"uuid":"#{@uuid_b}","weight":2}]})

      {hash, jcs} = Protocol.entry_hash({@draw_id, entries})

      assert jcs == expected_jcs
      assert hash == hex_sha256(expected_jcs)
      assert String.match?(hash, ~r/^[0-9a-f]{64}$/)
    end

    test "operator_ref present sorts alphabetically inside entry object" do
      entries = [%{uuid: @uuid_a, operator_ref: "alice", weight: 1}]

      expected_jcs =
        ~s({"draw_id":"#{@draw_id}","entries":[{"operator_ref":"alice","uuid":"#{@uuid_a}","weight":1}]})

      {_hash, jcs} = Protocol.entry_hash({@draw_id, entries})
      assert jcs == expected_jcs
    end

    test "empty-string operator_ref treated as nil (key omitted)" do
      nil_ref = [%{uuid: @uuid_a, operator_ref: nil, weight: 1}]
      empty = [%{uuid: @uuid_a, operator_ref: "", weight: 1}]

      assert Protocol.entry_hash({@draw_id, nil_ref}) == Protocol.entry_hash({@draw_id, empty})
    end

    test "same entries in different draw_ids produce different hashes" do
      entries = [%{uuid: @uuid_a, operator_ref: nil, weight: 1}]

      {h1, _} = Protocol.entry_hash({@draw_id, entries})
      {h2, _} = Protocol.entry_hash({@other_draw, entries})

      refute h1 == h2
    end
  end

  describe "entry_hash/1 — validation" do
    test "rejects non-positive-integer weights" do
      for bad <- [0, -1, 1.0, "1", nil] do
        entries = [%{uuid: @uuid_a, operator_ref: nil, weight: bad}]

        assert_raise ArgumentError, ~r/weight/i, fn ->
          Protocol.entry_hash({@draw_id, entries})
        end
      end
    end

    test "rejects malformed draw_id" do
      entries = [%{uuid: @uuid_a, operator_ref: nil, weight: 1}]

      for bad <- [
            "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
            "{aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa}",
            "urn:uuid:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "not-a-uuid",
            ""
          ] do
        assert_raise ArgumentError, ~r/draw_id/i, fn ->
          Protocol.entry_hash({bad, entries})
        end
      end
    end

    test "rejects malformed entry uuid" do
      for bad <- ["AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", "not-a-uuid", ""] do
        entries = [%{uuid: bad, operator_ref: nil, weight: 1}]

        assert_raise ArgumentError, ~r/uuid/i, fn ->
          Protocol.entry_hash({@draw_id, entries})
        end
      end
    end

    test "operator_ref accepts exactly 64 bytes" do
      sixty_four = String.duplicate("a", 64)
      entries = [%{uuid: @uuid_a, operator_ref: sixty_four, weight: 1}]

      assert {_, _} = Protocol.entry_hash({@draw_id, entries})
    end

    test "operator_ref limit is bytes, not codepoints" do
      # 33 x "é" = 66 bytes, 33 codepoints — over the byte limit
      over = String.duplicate("é", 33)
      entries = [%{uuid: @uuid_a, operator_ref: over, weight: 1}]

      assert_raise ArgumentError, ~r/operator_ref/i, fn ->
        Protocol.entry_hash({@draw_id, entries})
      end
    end

    test "rejects control chars in operator_ref" do
      bad_refs = [
        "\x00foo",
        "foo\x1F",
        "foo\x7Fbar",
        "line1\u{2028}line2",
        "para\u{2029}end"
      ]

      for bad <- bad_refs do
        entries = [%{uuid: @uuid_a, operator_ref: bad, weight: 1}]

        assert_raise ArgumentError, ~r/operator_ref/i, fn ->
          Protocol.entry_hash({@draw_id, entries})
        end
      end
    end
  end

  describe "compute_seed/3" do
    test "matches spec vector P-2" do
      drand_randomness = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
      entry_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      weather_value = "1013"

      expected_json =
        ~s({"drand_randomness":"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789","entry_hash":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","weather_value":"1013"})

      {seed_bytes, seed_json} =
        Protocol.compute_seed(entry_hash, drand_randomness, weather_value)

      assert seed_json == expected_json
      assert byte_size(seed_bytes) == 32
      assert seed_bytes == :crypto.hash(:sha256, expected_json)
    end

    test "JCS sorts keys alphabetically regardless of input key order" do
      {_seed, json} = Protocol.compute_seed("zzz_entry", "aaa_drand", "mmm_weather")

      assert json ==
               ~s({"drand_randomness":"aaa_drand","entry_hash":"zzz_entry","weather_value":"mmm_weather"})
    end
  end

  describe "compute_seed/2 (drand-only)" do
    test "produces a seed from drand and entry hash without weather" do
      drand_randomness = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
      entry_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

      expected_json =
        ~s({"drand_randomness":"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789","entry_hash":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"})

      {seed_bytes, seed_json} = Protocol.compute_seed(entry_hash, drand_randomness)

      assert seed_json == expected_json
      assert byte_size(seed_bytes) == 32
      assert seed_bytes == :crypto.hash(:sha256, expected_json)
    end

    test "drand-only seed differs from drand+weather seed with same inputs" do
      drand = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
      entry_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      weather = "1013"

      {seed_with_weather, _} = Protocol.compute_seed(entry_hash, drand, weather)
      {seed_drand_only, _} = Protocol.compute_seed(entry_hash, drand)

      assert seed_with_weather != seed_drand_only
    end

    test "weather_value key is absent, not null" do
      drand = "aaa"
      entry_hash = "bbb"

      {_seed, json} = Protocol.compute_seed(entry_hash, drand)

      refute String.contains?(json, "weather")
    end
  end

  defp hex_sha256(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end
end
