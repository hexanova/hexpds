defmodule Hipdster.Http do
  @moduledoc """
  The XRPC interface to the PDS, including AppView proxying
  """
  alias Hipdster.XRPC
  require XRPC

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["text/*"],
    json_decoder: Jason
  )

  get "/" do
    send_resp(conn, 200, """
    Hello from Hipdster
    ATProto PDS
    routes /xrpc/*

    Code on GitHub page
    find it at ovnanova
    slash hexpds
    """)
  end

  get "/favicon.ico" do
    send_resp(conn, 200, "Why would a PDS need a favicon?")
  end

  get "/.well-known/atproto-did" do
    {status, resp} =
      case Hipdster.User.get(conn.host) do
        %Hipdster.User{did: did} -> {200, did}
        _ -> {404, "User not found"}
      end

    send_resp(conn, status, resp)
  end

  get "/xrpc/:method" do
    conn = conn |> Plug.Conn.fetch_query_params()
    params = for {key, val} <- conn.query_params, into: %{}, do: {String.to_atom(key), val}

    {statuscode, json_body} =
      try do
        # We can handle the method
        IO.puts("Got query: #{method} #{inspect(params)}")
        xrpc_query(conn, method, params, :unauthenticated)
      catch
        _, e_from_method ->
          try do
            # We can't handle the method - try the appview
            case e_from_method do
              %FunctionClauseError{} -> IO.inspect(e_from_method)
              :function_clause -> IO.inspect(e_from_method)
              _ -> throw(e_from_method)
            end
            forward_query_to_appview(IO.inspect(appview_for(conn)), conn, method, params)
          catch
            _, e ->
              IO.inspect(e, label: "AppView proxying error")

              {500,
               %{
                 error: "Error",
                 message: "Oh no! Bad request or internal server error",
                 debug: inspect(e),
               }}
          end
      end

    case json_body do
      {:blob, blob} ->
        conn
        |> Plug.Conn.put_resp_content_type(blob.mime_type)
        |> Plug.Conn.send_resp(200, blob.data)
      _ ->
        send_resp(conn, statuscode, Jason.encode!(json_body))
    end
  end

  post "/xrpc/:method" do
    {:ok, body, conn} = read_body(conn)

    {statuscode, json_resp} =
      try do
        xrpc_procedure(conn, method, body, :unauthenticated)
      catch
        _, e ->
          {500,
           %{
             error: "Error",
             message: "Oh no! Bad request or internal server error: #{inspect(e)}",
             debug: Jason.encode!(e)
           }}
      end

    send_resp(conn, statuscode, Jason.encode!(json_resp))
  end

  defp appview_for(%Plug.Conn{} = c) do
    url_of(
      c.req_headers
      |> Enum.into(%{})
      |> Map.get("atproto-proxy")
    ) || Application.get_env(:hipdster, :appview_server)
  end

  def url_of(nil), do: nil

  # Caching wouldn't be a bad idea
  def url_of(atproto_proxy) do
    with [did, service] <- String.split(atproto_proxy, "#"),
         label <- "##{service}",
         {:ok, did_doc} <- Hipdster.Identity.get_did(did),
         %{"service" => services} <- did_doc,
         %{"serviceEndpoint" => "https://" <> endpoint} <-
           services
           |> Enum.find(fn
             %{"id" => ^label} -> true
             _ -> false
           end) do
      endpoint
    else
      err -> raise "Bad atproto-proxy header: #{inspect(err)}"
    end
  end

  defp forward_query_to_appview(appview, _conn, method, params) do
    # Ignore auth for now
    %{status_code: statuscode, body: json_body} =
      ("https://" <> appview <> "/xrpc/" <> method <> "?" <> URI.encode_query(params))
      |> HTTPoison.get!()

    {statuscode, Jason.decode!(json_body)}
  end

  @spec xrpc_query(Plug.Conn.t(), String.t(), map(), Hipdster.User.t() | :unauthenticated) :: {integer(), map() | {:blob, Hipdster.Blob.t()}}

  # As soon as we got JWTs we can do this!!!
  XRPC.query _, "app.bsky.actor.getPreferences", %{} do
    {200, %{preferences: %{}}}
  end

  XRPC.query _, "com.atproto.sync.getBlob", %{did: did, cid: cid} do
    with %Hipdster.Blob{} = blob <- Hipdster.Blob.get(cid, did) do
      {200, {:blob, blob}}
    else
      _ -> {400, %{error: "InvalidRequest", message: "No such blob"}}
    end
  end

  XRPC.query _, "com.atproto.sync.listBlobs", opts do
    case Hipdster.Xrpc.Query.ListBlobs.list_blobs(
           opts[:did],
           opts[:since],
           String.to_integer(opts[:limit] || 500),
           Hipdster.CID.decode_cid!(opts[:cursor])
         ) do
      %{cids: cids, cursor: next_cursor} ->
        {200, %{cursor: next_cursor, cids: Enum.map(cids, &to_string/1)}}

      other ->
        {400, %{error: "InvalidRequest", message: inspect(other)}}
    end
  end

  @spec xrpc_procedure(Plug.Conn.t(), String.t(), map(), Hipdster.User.t() | :unauthenticated) :: {integer(), map()}
  XRPC.procedure c, "com.atproto.server.createSession", %{identifier: username, password: pw} do
    {200, %{session: Hipdster.Auth.generate_session(c, username, pw)}}
  end
end
