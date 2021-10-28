defmodule FileStoreSftp.MixProject do
  use Mix.Project

  def project do
    [
      app: :file_store_sftp,
      name: "filestore-sftp",
      description: description(),
      version: "0.1.0",
      elixir: "~> 1.11",
      docs: docs(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: [
        licenses: ["MIT"],
        links: %{"Github" => "https://github.com/areinull/filestore-sftp"}
      ],
      source_url: "https://github.com/areinull/filestore-sftp"
    ]
  end

  def application do
    [
      extra_applications: [:ssh]
    ]
  end

  defp deps do
    [
      {:file_store, "~> 0.3"},
      {:ex_doc, "~> 0.19", only: [:dev, :doc], runtime: false}
    ]
  end

  defp docs do
    [
      source_url: "https://github.com/areinull/filestore-sftp",
      source_url_pattern: "https://github.com/areinull/filestore-sftp/%{path}#%{line}",
      main: "readme",
      language: "ru",
      extras: ["README.md"],
      groups_for_extras: [Документация: Path.wildcard("*.md")]
    ]
  end

  defp description do
    """
    Адаптер для FileStore, реализующий доступ к хранилищу по sftp.
    """
  end
end
