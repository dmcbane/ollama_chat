defmodule OllamaChat.PathGuardTest do
  use ExUnit.Case, async: true

  alias OllamaChat.PathGuard

  describe "validate_path/2" do
    test "absolute path under root is valid" do
      assert {:ok, "/root/sub/file.txt"} =
               PathGuard.validate_path("/root/sub/file.txt", "/root")
    end

    test "root itself is valid" do
      assert {:ok, "/root"} = PathGuard.validate_path("/root", "/root")
    end

    test "relative path is resolved under root" do
      assert {:ok, "/root/sub/file.txt"} =
               PathGuard.validate_path("sub/file.txt", "/root")
    end

    test "relative path with .. that stays under root is valid" do
      assert {:ok, "/root/other.txt"} =
               PathGuard.validate_path("sub/../other.txt", "/root")
    end

    test "absolute path outside root is rejected" do
      assert {:error, _} = PathGuard.validate_path("/etc/passwd", "/root")
    end

    test "relative path with .. that escapes root is rejected" do
      assert {:error, _} = PathGuard.validate_path("../../escape.txt", "/root")
    end

    test "dot resolves to root itself and is valid" do
      assert {:ok, "/root"} = PathGuard.validate_path(".", "/root")
    end

    test "path-prefix false-positive: /root-other is not under /root" do
      assert {:error, _} = PathGuard.validate_path("/root-other/file", "/root")
    end

    test "deeply nested relative path under root is valid" do
      assert {:ok, "/workspace/a/b/c/d/e.txt"} =
               PathGuard.validate_path("a/b/c/d/e.txt", "/workspace")
    end

    test "absolute path that is the root itself is valid" do
      assert {:ok, "/workspace"} = PathGuard.validate_path("/workspace", "/workspace")
    end
  end

  describe "sanitize_args/2" do
    test "empty args always passes" do
      assert {:ok, %{}} = PathGuard.sanitize_args(%{}, "/root")
    end

    test "non-path-like plain strings pass through unchanged" do
      args = %{"content" => "hello world", "encoding" => "utf-8"}
      assert {:ok, ^args} = PathGuard.sanitize_args(args, "/root")
    end

    test "safe absolute path arg passes through unchanged" do
      args = %{"path" => "/root/file.txt"}
      assert {:ok, ^args} = PathGuard.sanitize_args(args, "/root")
    end

    test "unsafe absolute path arg is rejected and error mentions the key name" do
      assert {:error, reason} =
               PathGuard.sanitize_args(%{"path" => "/etc/passwd"}, "/root")

      assert reason =~ "path"
    end

    test "unsafe relative path with .. is rejected" do
      assert {:error, _} =
               PathGuard.sanitize_args(%{"path" => "../../escape"}, "/root")
    end

    test "multiple args with one unsafe path is rejected" do
      args = %{"path" => "/root/ok.txt", "dest" => "/etc/shadow"}
      assert {:error, _} = PathGuard.sanitize_args(args, "/root")
    end

    test "plain filename without slashes is not path-like and passes through" do
      args = %{"path" => "README.md"}
      assert {:ok, ^args} = PathGuard.sanitize_args(args, "/root")
    end

    test "integer and boolean args pass through unchanged" do
      args = %{"count" => 5, "recursive" => true}
      assert {:ok, ^args} = PathGuard.sanitize_args(args, "/root")
    end

    test "path with .. that stays under root is valid" do
      args = %{"path" => "/root/sub/../file.txt"}
      assert {:ok, _} = PathGuard.sanitize_args(args, "/root")
    end

    test "home-relative path outside root is rejected" do
      # ~/Documents expands to the real home dir (e.g. /Users/alice/Documents),
      # which will not be under the fake root /root
      assert {:error, _} =
               PathGuard.sanitize_args(%{"path" => "~/Documents"}, "/root")
    end
  end
end
