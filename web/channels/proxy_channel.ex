defmodule PhoenixWsProxy.ProxyChannel do
  use PhoenixWsProxy.Web, :channel

  ###
  # Channel methods
  ###
  def join("proxy://" <> url, info, socket), do: join("proxy:/" <> url, info, socket)
  def join("proxy:/" <> url, info, socket), do: join("proxy:" <> url, info, socket)
  def join("proxy:" <> url, info, socket) do
    IO.puts "Connection established: #{url} => #{inspect info}"
    socket = assign(socket, :url, Path.join(Config.base_url, url))
      |> assign(:headers, setup_headers(info["session_id"]))
      |> assign(:shared, info["shared"])
    send self, :setup
    {:ok, nil, socket}
  end

  def handle_info(:setup, socket) do
    socket = setup(socket, socket.assigns.shared)
    {:noreply, socket}
  end

  def handle_info(:poll, socket) do
    {socket, timeout} = poll(socket)
    :timer.send_after(timeout, :poll)
    {:noreply, socket}
  end

  def handle_info({:data, pid}, socket) do
    send(pid, socket.assigns.data)
    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, poller, _reason}, %Phoenix.Socket{assigns: %{poller: poller}} = socket) do
    socket = setup(socket, socket.assigns.shared) # Recompete to become poller
    {:noreply, socket}
  end

  ###
  # Helper methods
  ###

  defp get_data(poller) do
    send(poller, {:data, self})
    receive do
      data -> data
    end
  end

  defp setup(socket, false) do
    send(self, :poll) # Do the polling ourselves
    socket
  end

  defp setup(socket, shared) when shared in [true, nil] do
    socket = assign(socket, :shared, true)
    case Global.register(self, socket.assigns.url, &Global.random_exit/3) do
      :yes -> # The first to look at this URL
        send self, :poll
        socket = assign(socket, :poller, self)
        socket
      :no -> # Someone else in the cluster is already watching this URL
        poller = Global.whereis(socket.assigns.url)
        Process.monitor poller # Watch for when they go down
        socket = assign(socket, :poller, poller)
          |> assign(:data, get_data(poller))
        push(socket, "data:update", socket.assigns.data)
        socket
    end
  end

  defp setup_headers(nil), do: %{}
  defp setup_headers(encrypted) do
    full_url = Regex.replace ~r/#{Config.encrypted_param}/, Path.join(Config.base_url, Config.authorize_url), encrypted
    {_, data} = get(full_url)
    %{"Cookie" => "#{Config.session_id_name}=#{get_in(data, Config.session_id_path)}"}
  end

  defp poll(socket) do
    {time, data} = get(socket.assigns.url, socket.assigns.headers)

    if data == socket.assigns[:data] do
      Logger.debug "#{inspect self} Completed #{socket.assigns.url} in #{inspect (time / 1000)}ms"
    else
      Logger.debug "#{inspect self} Data has changed"
      if socket.assigns.shared do
        broadcast!(socket, "data:update", data)
      else
        push(socket, "data:update", data)
      end
      socket = assign(socket, :data, data)
    end
    sleep_time = trunc(time * Config.sleep_factor / 1000)
    min_sleep = Config.min_sleep
    sleep_time = case sleep_time do
                   t when t > min_sleep -> t
                   _                    -> min_sleep
                 end
    Logger.debug "#{inspect self} Sleeping #{inspect (sleep_time / 1000)} sec"
    {socket, sleep_time}
  end

end
