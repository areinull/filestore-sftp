defmodule FileStoreSftp.Adapters.Sftp do
  @moduledoc """
  Stores files on the SFTP. Uses erlang `:ssh_sftp` module.

  ### Configuration

    * `host` - SFTP server host.

    * `port` - SFTP server port.

    * `user` - SFTP user name.

    * `password` - SFTP user password.

    * `base_path` - base path to use as a prefix for file operations on SFTP.

  ### Example

      iex> store = FileStoreSftp.Adapters.Sftp.new(
      ...>   host: "localhost",
      ...>   port: 22,
      ...>   user: "sftpuser",
      ...>   password: "sftppassword",
      ...>   base_path: "upload"
      ...> )
      %FileStoreSftp.Adapters.Sftp{...}

      iex> FileStore.write(store, "foo", "hello world")
      :ok

      iex> FileStore.read(store, "foo")
      {:ok, "hello world"}

  """

  @enforce_keys [:host, :port, :user, :password, :base_path, :chan, :ssh_ref]
  defstruct [:host, :port, :user, :password, :base_path, :chan, :ssh_ref]

  @spec new(keyword) :: FileStore.t()
  def new(opts) do
    for k <- [:host, :port, :user, :password, :base_path] do
      if is_nil(opts[k]) do
        raise "missing configuration: :#{k}"
      end
    end

    host = opts[:host] |> ensure_charlist()
    user = opts[:user] |> ensure_charlist()
    password = opts[:password] |> ensure_charlist()

    :ssh.start()

    {:ok, chan, ssh_ref} =
      :ssh_sftp.start_channel(host, opts[:port],
        user: user,
        password: password,
        silently_accept_hosts: true
      )

    struct(__MODULE__,
      host: host,
      port: opts[:port],
      user: user,
      password: password,
      base_path: opts[:base_path],
      chan: chan,
      ssh_ref: ssh_ref
    )
  end

  @spec stop(FileStore.t()) :: [term]
  def stop(%__MODULE__{chan: chan, ssh_ref: ssh_ref}) do
    [
      :ssh_sftp.stop_channel(chan),
      :ssh.close(ssh_ref)
    ]
  end

  @spec join(FileStore.t(), binary) :: Path.t()
  def join(store, key) do
    Path.join(store.base_path, key)
  end

  defp ensure_charlist(v) when is_binary(v), do: String.to_charlist(v)
  defp ensure_charlist(v) when is_list(v), do: v

  defimpl FileStore do
    alias FileStoreSftp.Adapters.Sftp

    def get_public_url(store, key, opts) do
      query =
        opts
        |> Keyword.take([:content_type, :disposition])
        |> FileStore.Utils.encode_query()

      uri = %URI{
        scheme: "sftp",
        host: store.host |> to_string(),
        port: store.port,
        path: "/" <> Sftp.join(store, key),
        query: query
      }

      URI.to_string(uri)
    end

    def get_signed_url(store, key, opts) do
      {:ok, get_public_url(store, key, opts)}
    end

    def stat(store, key) do
      with {:error, :closed} <- do_stat(store, key),
           {:ok, store} <- reconnect(store) do
        do_stat(store, key)
      end
    end

    def delete(store, key) do
      with {:error, :closed} <- do_delete(store, key),
           {:ok, store} <- reconnect(store) do
        do_delete(store, key)
      end
    end

    def delete_all(store, opts) do
      with {:error, :closed} <- do_delete_all(store, opts),
           {:ok, store} <- reconnect(store) do
        do_delete_all(store, opts)
      end
    end

    def write(store, key, content) do
      with {:error, :closed} <- do_write(store, key, content),
           {:ok, store} <- reconnect(store) do
        do_write(store, key, content)
      end
    end

    def read(store, key) do
      with {:error, :closed} <- do_read(store, key),
           {:ok, store} <- reconnect(store) do
        do_read(store, key)
      end
    end

    def upload(store, source, key) do
      with {:ok, content} <- File.read(source) do
        write(store, key, content)
      end
    end

    def download(store, key, dest) do
      with :ok <- File.touch(dest),
           {:ok, content} <- read(store, key) do
        File.write(dest, content)
      end
    end

    def list!(store, opts) do
      {:ok, files} = list(store, opts)
      files
    end

    defp list(store, opts) do
      with {:error, :closed} <- do_list(store, opts),
           {:ok, store} <- reconnect(store) do
        do_list(store, opts)
      end
    end

    defp do_stat(store, key) do
      with path <- Sftp.join(store, key) |> to_charlist(),
           {:ok, data} <- :ssh_sftp.read_file_info(store.chan, path),
           {:ok, content} <- :ssh_sftp.read_file(store.chan, path) do
        file_info = file_info_into_map(data)
        etag = FileStore.Stat.checksum(content)
        {:ok, %FileStore.Stat{key: key, size: file_info.size, etag: etag}}
      end
    end

    defp do_delete(store, key) do
      path = Sftp.join(store, key) |> to_charlist()

      with {:ok, data} <- :ssh_sftp.read_file_info(store.chan, path) do
        file_info = file_info_into_map(data)

        if file_info.type == :directory do
          delete_all(store, prefix: key)
        else
          :ssh_sftp.delete(store.chan, path)
        end
      else
        {:error, :no_such_file} -> :ok
        error -> error
      end
    end

    defp do_delete_all(store, opts) do
      with {:ok, files} <- list(store, opts) do
        files_del_result =
          Enum.reduce_while(files, :ok, fn file, _ ->
            case delete(store, file) do
              :ok ->
                {:cont, :ok}

              error ->
                {:halt, error}
            end
          end)

        with :ok <- files_del_result do
          prefix = Keyword.get(opts, :prefix, "")

          if prefix == "" do
            :ok
          else
            :ssh_sftp.del_dir(store.chan, Sftp.join(store, prefix) |> to_charlist())
          end
        end
      else
        {:error, :no_such_file} -> :ok
        error -> error
      end
    end

    defp do_write(store, key, content) do
      {dirs, _filename} =
        String.split(key, "/", trim: true)
        |> Enum.split(-1)

      Enum.reduce(dirs, "", fn dir, acc ->
        path = Sftp.join(store, Path.join(acc, dir)) |> to_charlist()

        case :ssh_sftp.list_dir(store.chan, path) do
          {:error, :no_such_file} ->
            :ssh_sftp.make_dir(store.chan, path)
            path

          _ ->
            path
        end
      end)

      delete(store, key)

      path = Sftp.join(store, key) |> to_charlist()
      :ssh_sftp.write_file(store.chan, path, content)
    end

    defp do_read(store, key) do
      path = Sftp.join(store, key) |> to_charlist()
      :ssh_sftp.read_file(store.chan, path)
    end

    defp do_list(store, opts) do
      prefix = Keyword.get(opts, :prefix, "")
      path = Sftp.join(store, prefix)

      with {:ok, files} <- :ssh_sftp.list_dir(store.chan, path),
           files <- Enum.filter(files, fn file -> file not in ['.', '..'] end),
           {:ok, files} <-
             Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
               new_prefix = Path.join(prefix, file)
               new_path = Sftp.join(store, new_prefix)

               with {:ok, data} <- :ssh_sftp.read_file_info(store.chan, new_path),
                    %{type: :directory} <- file_info_into_map(data),
                    {:ok, new_files} <- do_list(store, prefix: new_prefix) do
                 {:cont, {:ok, new_files ++ acc}}
               else
                 %{type: _} -> {:cont, {:ok, [new_prefix | acc]}}
                 error -> {:halt, error}
               end
             end) do
        Enum.map(files, &Path.join(prefix, to_string(&1)))
        {:ok, files}
      end
    end

    defp file_info_into_map(
           {:file_info, size, type, access, atime, mtime, ctime, mode, links, major_device, minor_device, inode, uid,
            gid}
         ) do
      %{
        size: size,
        type: type,
        access: access,
        atime: atime,
        mtime: mtime,
        ctime: ctime,
        mode: mode,
        links: links,
        major_device: major_device,
        minor_device: minor_device,
        inode: inode,
        uid: uid,
        gid: gid
      }
    end

    defp reconnect(store) do
      :ssh_sftp.stop_channel(store.chan)
      :ssh.close(store.ssh_ref)
      :ssh.stop()
      :timer.sleep(1000)

      with :ok <- :ssh.start(),
           {:ok, chan, ssh_ref} <-
             :ssh_sftp.start_channel(store.host, store.port,
               user: store.user,
               password: store.password,
               silently_accept_hosts: true
             ) do
        {:ok, %{store | chan: chan, ssh_ref: ssh_ref}}
      end
    end
  end
end
