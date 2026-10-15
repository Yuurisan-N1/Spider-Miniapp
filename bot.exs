Code.require_file("utils/json.ex", __DIR__)
Code.require_file("utils/banner.ex", __DIR__)

defmodule SpiderMiner do
  @moduledoc false

  @my_project "Spider Miner Miniapp"
  @base_url "https://app.spiderminer.lol/api"
  @origin "https://app.spiderminer.lol"
  @root __DIR__
  @symbol "SPID"
  @ad_dwell 16
  @start_attempts 4
  @gap_limit 60

  @user_agent "Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

  @reset "\e[0m"
  @bold "\e[1m"
  @red "\e[91m"
  @green "\e[92m"
  @yellow "\e[93m"

  def run do
    :logger.set_primary_config(:level, :error)
    install_signal_handler()

    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    Banner.set_title(@my_project)
    Banner.show_banner(@my_project)

    accounts = load_lines("data.txt")

    if accounts == [] do
      red("File data.txt is empty, please add your initData entries")
      System.halt(1)
    end

    proxies = load_lines("proxy.txt")
    settings = load_settings()

    loop(accounts, proxies, settings, 1)
  end

  defp loop(accounts, proxies, settings, cycle) do
    yellow("Starting automation cycle number #{cycle}")

    Enum.with_index(accounts)
    |> Enum.each(fn {account, index} ->
      if index > 0, do: IO.puts("")

      proxy = proxy_for(proxies, index)

      case proxy do
        nil -> :ok
        line -> yellow("Using proxy #{mask_proxy(line)}")
      end

      try do
        process_account(account, index, proxy)
      rescue
        _error -> red("Account #{index + 1} was skipped after an error")
      end
    end)

    yellow("All accounts processed for cycle number #{cycle}")

    countdown(sleep_seconds(settings), "Next cycle starts in")
    Banner.show_banner(@my_project)
    loop(accounts, proxies, settings, cycle + 1)
  end

  defp process_account(line, index, proxy) do
    label = "#{index + 1}"

    case identity(line) do
      {:ok, init_data, id, username, first_name} ->
        case register_device(init_data, proxy) do
          {:ok, key} ->
            ctx = %{
              label: label,
              init: init_data,
              id: id,
              username: username,
              first_name: first_name,
              key: key,
              proxy: proxy,
              balance: 0
            }

            open_account(ctx)

          {:error, _reason} ->
            red("Account #{label} device check failed on this run")
        end

      {:error, _reason} ->
        red("Account #{label} init data was refused by the server")
    end
  end

  defp open_account(ctx) do
    case api(ctx, :get, "bootstrap", nil) do
      {:ok, state} ->
        user = get(state, "user", %{})
        ctx = %{ctx | balance: balance_of(user)}

        cond do
          get(state, "maintenance") ->
            yellow("Account #{ctx.label} was skipped because the app is under maintenance")

          get(state, "banned") || get(user, "banned", false) ->
            red("Account #{ctx.label} is banned in the app")

          get(state, "gate") ->
            yellow("Account #{ctx.label} still needs the mandatory channels joined in the app")

          true ->
            green(
              "Welcome back #{clean_text(get(user, "firstName", "Unknown"), "user")} with balance #{format_amount(ctx.balance)} #{@symbol}"
            )

            run_phases(ctx)
        end

      {:error, _reason} ->
        red("Account #{ctx.label} login attempt failed on this run")
    end
  end

  defp run_phases(ctx) do
    {ctx, daily_count} = run_daily(ctx)
    {ctx, job_count} = run_jobs(ctx)
    {ctx, mine_count} = run_mining(ctx)
    {ctx, ad_count} = run_ads(ctx)
    {ctx, crew_count} = run_crew(ctx)

    total = daily_count + job_count + mine_count + ad_count + crew_count

    if total > 0 do
      green("All available tasks were completed and #{plural(total, "reward")} claimed")
    else
      green("Every available account task was already completed")
    end

    ctx
  end

  defp run_daily(ctx) do
    case api(ctx, :get, "tasks", nil) do
      {:ok, data} ->
        daily = get(data, "daily", %{})

        {ctx, count} = daily_checkin(ctx, get(daily, "checkin"))
        {ctx, count} = daily_story(ctx, get(daily, "story"), count)
        {ctx, count} = daily_bio(ctx, get(daily, "bio"), count)
        {ctx, count} = daily_home(ctx, get(daily, "home"), count)

        ctx = Map.put(ctx, :tasks, data)
        {ctx, count}

      {:error, _reason} ->
        red("Daily rewards could not be read")
        {ctx, 0}
    end
  end

  defp daily_checkin(ctx, nil), do: {ctx, 0}

  defp daily_checkin(ctx, checkin) do
    if get(checkin, "claimed", false) do
      {ctx, 0}
    else
      case claim_with_ad(ctx, "quests/checkin", "checkin") do
        {:ok, data} -> credit(ctx, "Daily check-in", data)
        {:error, reason} -> refuse(ctx, "Daily check-in", reason)
      end
    end
  end

  defp daily_story(ctx, nil, count), do: {ctx, count}

  defp daily_story(ctx, story, count) do
    cond do
      get(story, "claimed", false) ->
        {ctx, count}

      is_nil(get(story, "openedAt")) ->
        case api(ctx, :post, "story/start", %{}) do
          {:ok, started} ->
            wait(get(story, "timer", 15), "Next story read in")
            claim_story(ctx, started, count)

          {:error, reason} ->
            case refuse(ctx, "Story reward", reason) do
              {ctx, added} -> {ctx, count + added}
            end
        end

      true ->
        wait(get(story, "timer", 15), "Next story read in")
        claim_story(ctx, %{}, count)
    end
  end

  defp claim_story(ctx, _started, count) do
    case api(ctx, :post, "story/claim", %{}) do
      {:ok, data} ->
        case credit(ctx, "Story", data) do
          {ctx, 1} -> {ctx, count + 1}
          {ctx, _} -> {ctx, count}
        end

      {:error, reason} ->
        case refuse(ctx, "Story", reason) do
          {ctx, added} -> {ctx, count + added}
        end
    end
  end

  defp daily_bio(ctx, nil, count), do: {ctx, count}

  defp daily_bio(ctx, bio, count) do
    if get(bio, "enabled", false) && !get(bio, "doneToday", false) do
      case api(ctx, :post, "bio/verify", %{}) do
        {:ok, data} ->
          case credit(ctx, "Bio link", data) do
            {ctx, 1} -> {ctx, count + 1}
            {ctx, _} -> {ctx, count}
          end

        {:error, reason} ->
          case refuse(ctx, "Bio link", reason) do
            {ctx, added} -> {ctx, count + added}
          end
      end
    else
      {ctx, count}
    end
  end

  defp daily_home(ctx, nil, count), do: {ctx, count}

  defp daily_home(ctx, home, count) do
    if get(home, "done", false) do
      {ctx, count}
    else
      case api(ctx, :post, "home/claim", %{"status" => "added"}) do
        {:ok, data} ->
          case credit(ctx, "Home screen", data) do
            {ctx, 1} -> {ctx, count + 1}
            {ctx, _} -> {ctx, count}
          end

        {:error, reason} ->
          case refuse(ctx, "Home screen", reason) do
            {ctx, added} -> {ctx, count + added}
          end
      end
    end
  end

  defp run_jobs(ctx) do
    jobs =
      get(Map.get(ctx, :tasks, %{}), "jobs", [])
      |> Enum.filter(fn job -> get(job, "status", "new") != "done" end)

    if jobs == [] do
      {ctx, 0}
    else
      Enum.reduce(jobs, {ctx, 0}, fn job, {ctx, count} ->
        {ctx, added} = claim_job(ctx, job)
        {ctx, count + added}
      end)
    end
  end

  defp claim_job(ctx, job) do
    title = clean_text(get(job, "title", "task"), "task")
    id = get(job, "id")

    case api(ctx, :post, "tasks/#{id}/start", %{}) do
      {:ok, _} ->
        wait(get(job, "timer", 15), "Next task claim in")

        case claim_with_ad(ctx, "tasks/#{id}/claim", "task") do
          {:ok, data} -> credit(ctx, "Task #{title}", data)
          {:error, reason} -> refuse(ctx, "Task #{title}", reason)
        end

      {:error, reason} ->
        refuse(ctx, "Task #{title}", reason)
    end
  end

  defp run_mining(ctx) do
    case api(ctx, :get, "mine", nil) do
      {:ok, state} ->
        user = get(state, "user", %{})
        mine = get(state, "mine", %{})
        ctx = %{ctx | balance: balance_of(user)}

        cond do
          get(mine, "needWallet", false) ->
            yellow("Mining was skipped because no TON wallet is linked")
            {ctx, 0}

          get(get(mine, "shift", %{}), "done", false) ->
            case claim_with_ad(ctx, "mine/claim", "claim") do
              {:ok, data} ->
                case credit(ctx, "Mining shift", data) do
                  {ctx, 1} -> {ctx, 1}
                  {ctx, _} -> {ctx, 0}
                end

              {:error, reason} ->
                refuse(ctx, "Mining shift", reason)
            end

          true ->
            shift = get(mine, "shift", %{})
            left = shift_left(shift)

            if left > 0 do
              yellow("Mining shift is still running and finishes in #{format_duration(left)}")
            else
              yellow("Mining shift is still running and the reward is not ready yet")
            end

            {ctx, 0}
        end

      {:error, _reason} ->
        red("Mining state could not be read")
        {ctx, 0}
    end
  end

  defp run_ads(ctx) do
    {ctx, sponsored} = run_sponsored(ctx)
    {ctx, network} = run_networks(ctx)
    {ctx, sponsored + network}
  end

  defp run_sponsored(ctx) do
    case get(Map.get(ctx, :tasks, %{}), "adsgramTasks") do
      %{"blocks" => [block | _]} = rail ->
        limit = get(rail, "limit", 0)
        today = get(rail, "today", 0)

        if today >= limit do
          green("Sponsored task rail was already fully claimed for today")
          {ctx, 0}
        else
          sponsored_loop(ctx, block, limit - today, 0)
        end

      _ ->
        {ctx, 0}
    end
  end

  defp sponsored_loop(ctx, block, left, count) do
    sponsored_attempt(ctx, block, left, count, 1)
  end

  defp sponsored_attempt(ctx, _block, left, count, _attempt) when left <= 0, do: {ctx, count}

  defp sponsored_attempt(ctx, block, left, count, attempt) do
    case api(ctx, :post, "adsgram-task/reward", %{"blockId" => block}) do
      {:ok, data} ->
        case credit(ctx, "Sponsored task", data) do
          {ctx, 1} -> sponsored_attempt(ctx, block, left - 1, count + 1, 1)
          {ctx, _} -> {ctx, count}
        end

      {:error, reason} ->
        sponsored_backoff(ctx, block, left, count, attempt, reason)
    end
  end

  defp sponsored_backoff(ctx, block, left, count, attempt, reason) do
    pause = cooling_pause(reason, attempt)

    if cooling?(reason) and attempt < @start_attempts and pause <= @gap_limit do
      countdown(pause, "Next sponsored task in")
      sponsored_attempt(ctx, block, left, count, attempt + 1)
    else
      case refuse(ctx, "Sponsored task", reason) do
        {ctx, added} -> {ctx, count + added}
      end
    end
  end

  defp run_networks(ctx) do
    case api(ctx, :get, "earn", nil) do
      {:ok, data} ->
        networks =
          get(data, "networks", [])
          |> Enum.filter(fn net -> get(net, "today", 0) < get(net, "dailyLimit", 0) end)

        if networks == [] do
          green("Every ad network rail was already fully claimed for today")
          {ctx, 0}
        else
          Enum.reduce(networks, {ctx, 0}, fn net, {ctx, count} ->
            {ctx, added} = network_loop(ctx, net, get(net, "dailyLimit", 0) - get(net, "today", 0), 0)
            {ctx, count + added}
          end)
        end

      {:error, _reason} ->
        red("Ad networks could not be read")
        {ctx, 0}
    end
  end

  defp network_loop(ctx, net, left, count) do
    network_attempt(ctx, net, left, count, 1)
  end

  defp network_attempt(ctx, _net, left, count, _attempt) when left <= 0, do: {ctx, count}

  defp network_attempt(ctx, net, left, count, attempt) do
    case api(ctx, :post, "ads/start", %{"networkId" => get(net, "id")}) do
      {:ok, started} ->
        case get(started, "token") do
          nil ->
            network_backoff(ctx, net, left, count, attempt, get(started, "error", "no ad session was returned"))

          token ->
            wait(@ad_dwell, "Next ad watch in")
            network_complete(ctx, net, token, left, count)
        end

      {:error, reason} ->
        network_backoff(ctx, net, left, count, attempt, reason)
    end
  end

  defp network_backoff(ctx, net, left, count, attempt, reason) do
    pause = cooling_pause(reason, attempt)

    if cooling?(reason) and attempt < @start_attempts and pause <= @gap_limit do
      countdown(pause, "Next ad network start in")
      network_attempt(ctx, net, left, count, attempt + 1)
    else
      case refuse(ctx, "Ad network", reason) do
        {ctx, added} -> {ctx, count + added}
      end
    end
  end

  defp network_complete(ctx, net, token, left, count) do
    network_claim(ctx, net, token, left, count, 1)
  end

  defp network_claim(ctx, net, token, left, count, attempt) do
    case api(ctx, :post, "ads/complete", %{"token" => token}) do
      {:ok, data} ->
        case credit(ctx, "Ad network", data) do
          {ctx, 1} -> network_loop(ctx, net, left - 1, count + 1)
          {ctx, _} -> {ctx, count}
        end

      {:error, reason} ->
        pause = if dwell_retry?(reason), do: @ad_dwell, else: cooling_pause(reason, attempt)
        more = (dwell_retry?(reason) or cooling?(reason)) and attempt < @start_attempts

        if more and pause <= @gap_limit do
          yellow("Ad network wants a longer watch, so the claim is tried once more")
          countdown(pause, "Next ad claim attempt in")
          network_claim(ctx, net, token, left, count, attempt + 1)
        else
          case refuse(ctx, "Ad network", reason) do
            {ctx, added} -> {ctx, count + added}
          end
        end
    end
  end

  defp run_crew(ctx) do
    case api(ctx, :get, "crew", nil) do
      {:ok, data} ->
        if get(get(data, "bonus", %{}), "pending", 0) > 0 do
          case api(ctx, :post, "crew/claim", %{}) do
            {:ok, claimed} -> credit(ctx, "Crew bonus", claimed)
            {:error, reason} -> refuse(ctx, "Crew bonus", reason)
          end
        else
          {ctx, 0}
        end

      {:error, _reason} ->
        red("Crew summary could not be read")
        {ctx, 0}
    end
  end

  defp claim_with_ad(ctx, path, kind) do
    case api(ctx, :post, path, %{"check" => true}) do
      {:ok, pre} ->
        if get(pre, "needAd", false) do
          case api(ctx, :post, "claim-ad/start", %{"kind" => kind}) do
            {:ok, ad} ->
              if get(ad, "required", false) do
                {:error, "an ad is required for this claim"}
              else
                api(ctx, :post, path, %{})
              end

            {:error, reason} ->
              {:error, reason}
          end
        else
          api(ctx, :post, path, %{})
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp credit(ctx, label, data) do
    case balance_of(get(data, "user", nil)) do
      nil ->
        yellow("#{label} answered but no reward was confirmed")

        case refresh_balance(ctx) do
          {ctx, gained} -> confirmed(ctx, label, gained)
        end

      fresh ->
        confirmed(%{ctx | balance: fresh}, label, fresh - ctx.balance)
    end
  end

  defp confirmed(ctx, label, gained) when gained > 0 do
    green("#{label} reward of #{format_amount(gained)} #{@symbol} was claimed on this run")
    {ctx, 1}
  end

  defp confirmed(ctx, label, _gained) do
    yellow("#{label} answered but no reward was confirmed")
    {ctx, 0}
  end

  defp refresh_balance(ctx) do
    case api(ctx, :get, "mine", nil) do
      {:ok, state} ->
        fresh = balance_of(get(state, "user", %{}))

        if is_number(fresh) do
          {%{ctx | balance: fresh}, fresh - ctx.balance}
        else
          {ctx, 0}
        end

      {:error, _} ->
        {ctx, 0}
    end
  end

  defp cooling?(reason) do
    text = String.downcase(to_string(reason))

    Enum.any?(["wait", "cool", "too early", "too short", "slow down", "in a row"], fn word ->
      String.contains?(text, word)
    end)
  end

  defp dwell_retry?(reason) do
    text = String.downcase(to_string(reason))

    Enum.any?(["early", "too short", "watch the full", "complete the ad"], fn word ->
      String.contains?(text, word)
    end)
  end

  defp cooldown_secs(reason) do
    text = String.downcase(to_string(reason))

    case Regex.run(~r/(\d+)\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?|s|m|h)\b/, text) do
      [_, value, unit] -> cooldown_scale(String.to_integer(value), unit)
      _ -> 0
    end
  end

  defp cooldown_scale(value, unit) when unit in ["h", "hr", "hrs", "hour", "hours"], do: value * 3600
  defp cooldown_scale(value, unit) when unit in ["m", "min", "mins", "minute", "minutes"], do: value * 60
  defp cooldown_scale(value, _unit), do: value

  defp cooling_pause(reason, attempt) do
    case cooldown_secs(reason) do
      secs when secs > 0 -> secs + 2
      _ -> 5 * attempt
    end
  end

  defp refuse(ctx, label, reason) do
    code = String.upcase(to_string(reason))

    cond do
      String.contains?(code, "LIMIT") ->
        yellow("#{label} was skipped because the daily limit was reached")
        {ctx, 0}

      String.contains?(code, "WAIT") or String.contains?(code, "COOL") or String.contains?(code, "EARLY") ->
        {ctx, 0}

      String.contains?(code, "ALREADY") ->
        yellow("#{label} was already claimed today on this account")
        {ctx, 0}

      String.contains?(code, "JOIN") or String.contains?(code, "CHANNEL") ->
        yellow("#{label} still needs a manual channel join")
        {ctx, 0}

      String.contains?(code, "TAP START") ->
        yellow("#{label} still needs the bot started from the Telegram chat")
        {ctx, 0}

      String.contains?(code, "WALLET") ->
        yellow("#{label} was skipped because no TON wallet is linked")
        {ctx, 0}

      true ->
        red("#{label} was refused by the server")
        {ctx, 0}
    end
  end

  defp register_device(init_data, proxy) do
    case request(:get, "device/challenge", nil, init_data, nil, proxy) do
      {:ok, challenge} ->
        nonce = get(challenge, "nonce")
        counter = solve(nonce, get(challenge, "bits", 0))

        payload =
          device_values()
          |> Map.merge(%{
            "platform" => "android",
            "info" => %{
            "screen" => "1080x2340@2.75",
            "tz" => "Asia/Jakarta",
            "lang" => "en-US",
            "gpu" => "Adreno (TM) 640",
            "tgv" => "7.11"
          },
          "env" => %{
            "webdriver" => false,
            "headless" => false,
            "tgPlatform" => "android",
            "tgVersion" => "7.11",
            "touch" => 5,
            "sw" => 1080,
            "sh" => 2340
          },
          "pow" => %{"nonce" => nonce, "counter" => to_string(counter)}
          })

        case request(:post, "device", payload, init_data, nil, proxy) do
          {:ok, device} ->
            case get(device, "appKey") do
              nil -> {:error, "the device key was not returned"}
              key -> {:ok, key}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp solve(nonce, bits) when is_integer(bits) do
    solve(nonce, bits, 0)
  end

  defp solve(_nonce, _bits), do: 0

  defp solve(nonce, bits, counter) do
    digest = :crypto.hash(:sha256, "#{nonce}:#{counter}")
    if leading_zeros(digest) >= bits, do: counter, else: solve(nonce, bits, counter + 1)
  end

  defp leading_zeros(binary), do: leading_zeros(binary, 0)

  defp leading_zeros(<<0, rest::binary>>, count), do: leading_zeros(rest, count + 8)
  defp leading_zeros(<<byte, _rest::binary>>, count), do: count + 8 - bit_length(byte)
  defp leading_zeros(<<>>, count), do: count

  defp bit_length(0), do: 0
  defp bit_length(value), do: bit_length(value, 0)
  defp bit_length(0, count), do: count
  defp bit_length(value, count), do: bit_length(div(value, 2), count + 1)

  defp device_values do
    %{
      "fp" => random_hex(),
      "did" => random_hex()
    }
  end

  defp random_hex do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp identity(line) do
    init_data =
      line
      |> String.split("|")
      |> List.first()
      |> String.trim()

    with {:ok, params} <- parse_query(init_data),
         raw when is_binary(raw) <- Map.get(params, "user"),
         {:ok, user} <- YuurisanJSON.decode(URI.decode_www_form(raw)),
         id when not is_nil(id) <- get(user, "id") do
      {:ok, init_data, to_string(id), get(user, "username", ""), get(user, "first_name", "")}
    else
      nil -> {:error, "the user object is missing"}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "initData could not be read"}
    end
  end

  defp parse_query(raw) do
    pairs =
      raw
      |> String.trim()
      |> String.split("&")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [key, value] -> {key, value}
          [key] -> {key, ""}
        end
      end)

    if Enum.any?(pairs, fn {key, _} -> key == "hash" end) do
      {:ok, Map.new(pairs)}
    else
      {:error, "initData has no hash field"}
    end
  end

  defp api(ctx, method, path, payload) do
    case request(method, path, payload, ctx.init, ctx.key, ctx.proxy) do
      {:ok, body} -> unwrap(body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp unwrap(body) when is_map(body) do
    case body do
      %{"error" => error} -> {:error, error}
      %{} = data -> {:ok, data}
    end
  end

  defp unwrap(_body), do: {:ok, %{}}

  defp request(method, path, payload, init_data, key, proxy) do
    url = String.to_charlist(@base_url <> "/" <> path)
    {profile, auth} = proxy_setup(proxy)

    headers =
      [
        {~c"content-type", ~c"application/json"},
        {~c"accept", ~c"*/*"},
        {~c"accept-language", ~c"en-US,en;q=0.9"},
        {~c"origin", String.to_charlist(@origin)},
        {~c"referer", String.to_charlist(@origin <> "/")},
        {~c"x-init-data", String.to_charlist(init_data)},
        {~c"user-agent", String.to_charlist(@user_agent)}
      ] ++ if(key, do: [{~c"x-app-key", String.to_charlist(key)}], else: [])

    options = [ssl: [verify: :verify_none], timeout: 30_000, connect_timeout: 15_000] ++ auth

    http_request =
      case method do
        :get -> {:get, {url, headers}}
        :post -> {:post, {url, headers, ~c"application/json", YuurisanJSON.encode(payload || %{})}}
      end

    case :httpc.request(elem(http_request, 0), elem(http_request, 1), options, [body_format: :binary], profile) do
      {:ok, {{_, status, _}, _, response}} when status >= 200 and status < 300 ->
        case YuurisanJSON.decode(response) do
          {:ok, value} -> {:ok, value}
          {:error, _} -> {:error, "response could not be parsed"}
        end

      {:ok, {{_, status, _}, _, response}} ->
        case YuurisanJSON.decode(response) do
          {:ok, %{"error" => error}} -> {:error, error}
          {:ok, %{"message" => message}} -> {:error, message}
          {:ok, _} -> {:error, "server returned status #{status}"}
          {:error, _} -> {:error, "server returned status #{status}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp proxy_setup(nil), do: {:default, []}

  defp proxy_setup(line) do
    case parse_proxy(line) do
      {host, port, user, pass} -> proxy_profile(host, port, user, pass)
      {host, port} -> proxy_profile(host, port, "", "")
      nil -> {:default, []}
    end
  end

  defp proxy_profile(host, port, user, pass) do
    name = String.to_atom("proxy_#{host}_#{port}")
    address = {String.to_charlist(host), port}

    case :inets.start(:httpc, profile: name) do
      {:ok, _pid} -> :httpc.set_options([proxy: {address, []}, https_proxy: {address, []}], name)
      {:error, {:already_started, _pid}} -> :ok
      _ -> :ok
    end

    case user do
      "" -> {name, []}
      _ -> {name, [proxy_auth: {String.to_charlist(user), String.to_charlist(pass)}]}
    end
  end

  defp parse_proxy(line) do
    value =
      line
      |> String.trim()
      |> String.replace_prefix("http://", "")
      |> String.replace_prefix("https://", "")
      |> String.replace_prefix("socks5://", "")

    case String.split(value, "@") do
      [credentials, host_part] ->
        case String.split(credentials, ":") do
          [user, pass] -> with_host_port(host_part, user, pass)
          _ -> with_host_port(host_part, "", "")
        end

      [host_part] ->
        case String.split(host_part, ":") do
          [host, port] -> with_port(host, port)
          [host, port, user, pass] -> with_port_creds(host, port, user, pass)
          _ -> nil
        end
    end
  end

  defp with_host_port(host_part, user, pass) do
    case String.split(host_part, ":") do
      [host, port] -> with_port_creds(host, port, user, pass)
      _ -> nil
    end
  end

  defp with_port(host, port) do
    case Integer.parse(port) do
      {number, ""} -> {host, number}
      _ -> nil
    end
  end

  defp with_port_creds(host, port, user, pass) do
    case Integer.parse(port) do
      {number, ""} -> {host, number, user, pass}
      _ -> nil
    end
  end

  defp mask_proxy(line) do
    case parse_proxy(line) do
      {host, port, _user, _pass} -> "http://user:pass@#{mask_host(host)}:#{port}"
      {host, port} -> "http://user:pass@#{mask_host(host)}:#{port}"
      nil -> "http://user:pass@***:***"
    end
  end

  defp mask_host(host) do
    parts = String.split(host, ".")

    case parts do
      [a, _b, _c, d] ->
        "#{a}*****#{d}"

      _ ->
        if String.length(host) > 4 do
          String.slice(host, 0, 2) <> "*****" <> String.slice(host, -2, 2)
        else
          "***"
        end
    end
  end

  defp proxy_for([], _index), do: nil
  defp proxy_for(proxies, index), do: Enum.at(proxies, rem(index, length(proxies)))

  defp load_lines(name) do
    case File.read(Path.join(@root, name)) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:error, _} ->
        []
    end
  end

  defp load_settings do
    case File.read(Path.join(@root, "config.json")) do
      {:ok, content} ->
        case YuurisanJSON.decode(content) do
          {:ok, value} -> value
          {:error, _} -> default_settings()
        end

      {:error, _} ->
        settings = default_settings()
        File.write(Path.join(@root, "config.json"), YuurisanJSON.encode(settings))
        settings
    end
  end

  defp default_settings, do: %{"settings" => %{"sleep_seconds" => 3600}}

  defp sleep_seconds(settings) do
    case get(get(settings, "settings", %{}), "sleep_seconds", 3600) do
      value when is_integer(value) and value > 0 -> value
      value when is_float(value) and value > 0 -> trunc(value)
      _ -> 3600
    end
  end


  defp get(map, key, default \\ nil)
  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp get(_other, _key, default), do: default

  defp clean_text(value, fallback) do
    text = value |> stringify() |> String.split() |> Enum.join(" ")

    case text do
      "" -> fallback
      cleaned -> cleaned
    end
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp stringify({:failed_connect, _}), do: "no network connection"
  defp stringify({:timeout, _}), do: "the request timed out"
  defp stringify({:failed_connect, _, _}), do: "no network connection"
  defp stringify(nil), do: "error"
  defp stringify(value), do: inspect(value)

  defp format_amount(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 2)
  end

  defp format_amount(value), do: to_string(value)

  defp balance_of(nil), do: nil

  defp balance_of(user) do
    case get(user, "balance", nil) do
      value when is_number(value) -> value
      _ -> nil
    end
  end

  defp shift_left(shift) do
    ends = get(shift, "end", 0)

    if is_number(ends) do
      left = trunc((ends - System.system_time(:millisecond)) / 1000)
      max(left, 0)
    else
      0
    end
  end

  defp install_signal_handler do
    handler = fn ->
      IO.write("\n" <> @red <> @bold <> "Script stopped by user" <> @reset <> "\n")
      System.halt(0)
    end

    try do
      System.trap_signal(:sigint, handler)
    rescue
      _ -> :ok
    end

    try do
      System.trap_signal(:sigterm, handler)
    rescue
      _ -> :ok
    end
  end

  defp plural(count, word) do
    if count == 1, do: "#{count} #{word}", else: "#{count} #{pluralize(word)}"
  end

  defp pluralize(word) do
    if String.ends_with?(word, "y") do
      String.slice(word, 0, String.length(word) - 1) <> "ies"
    else
      word <> "s"
    end
  end

  defp wait(seconds, label) do
    left = max(trunc(seconds), 0)

    if left >= 1 do
      width = frame(label, left, 0)
      tick(left, label, width)
    end
  end

  defp countdown(seconds, label) do
    left = max(trunc(seconds), 0)

    if left >= 1 do
      width = frame(label, left, 0)
      tick(left, label, width)
    end
  end

  defp tick(0, _label, width) do
    IO.write("\r" <> String.duplicate(" ", width) <> "\r")
  end

  defp tick(left, label, width) do
    width = frame(label, left, width)
    :timer.sleep(1000)
    tick(left - 1, label, width)
  end

  defp frame(label, left, width) do
    text = label <> " " <> format_duration(left)
    IO.write("\r" <> @yellow <> @bold <> text <> @reset)
    max(width, String.length(text))
  end

  defp format_duration(total) do
    days = div(total, 86_400)
    hours = div(rem(total, 86_400), 3600)
    minutes = div(rem(total, 3600), 60)
    seconds = rem(total, 60)

    if days > 0 do
      pad(days) <> ":" <> pad(hours) <> ":" <> pad(minutes) <> ":" <> pad(seconds)
    else
      pad(hours) <> ":" <> pad(minutes) <> ":" <> pad(seconds)
    end
  end

  defp pad(value), do: String.pad_leading(Integer.to_string(value), 2, "0")

  defp green(message), do: IO.puts(@green <> @bold <> message <> @reset)
  defp yellow(message), do: IO.puts(@yellow <> @bold <> message <> @reset)
  defp red(message), do: IO.puts(@red <> @bold <> message <> @reset)
end

SpiderMiner.run()
