defmodule Anubis.Server.Session.StoreTest do
  use ExUnit.Case, async: false

  alias Anubis.Server.Session
  alias Anubis.Server.Session.Supervisor, as: SessionSupervisor
  alias Anubis.Test.MockSessionStore

  @moduletag capture_log: true

  setup do
    # Start the mock store
    start_supervised!(MockSessionStore)
    MockSessionStore.reset!()

    # Configure the application to use the mock store
    original_config = Application.get_env(:anubis_mcp, :session_store)

    Application.put_env(:anubis_mcp, :session_store,
      enabled: true,
      adapter: MockSessionStore,
      ttl: 1800
    )

    on_exit(fn ->
      if original_config do
        Application.put_env(:anubis_mcp, :session_store, original_config)
      else
        Application.delete_env(:anubis_mcp, :session_store)
      end
    end)

    :ok
  end

  describe "session persistence" do
    test "saves session state when initialized" do
      session_id = "test_session_123"
      start_supervised!({Registry, keys: :unique, name: TestSessionRegistry})
      session_name = {:via, Registry, {TestSessionRegistry, session_id}}

      # Start a session
      start_supervised!({Session, session_id: session_id, name: session_name, server_module: TestServer})

      # Initialize the session
      Session.update_from_initialization(
        session_name,
        "2024-11-21",
        %{"name" => "test_client", "version" => "1.0.0"},
        %{"tools" => %{}}
      )

      Session.mark_initialized(session_name)

      # Check that session was persisted
      {:ok, stored_state} = MockSessionStore.load(session_id, [])
      assert stored_state.protocol_version == "2024-11-21"
      assert stored_state.initialized == true
      assert stored_state.client_info["name"] == "test_client"
    end

    test "restores session from store on startup" do
      session_id = "existing_session_456"
      start_supervised!({Registry, keys: :unique, name: TestSessionRegistry2})

      # Pre-populate store with session data
      session_data = %{
        id: session_id,
        protocol_version: "2024-11-21",
        initialized: true,
        client_info: %{"name" => "restored_client"},
        client_capabilities: %{"tools" => %{}},
        log_level: "info",
        pending_requests: %{}
      }

      :ok = MockSessionStore.save(session_id, session_data, [])

      # Start a new session with the same ID
      session_name = {:via, Registry, {TestSessionRegistry2, session_id}}

      start_supervised!({Session, session_id: session_id, name: session_name, server_module: TestServer})

      # Verify the session was restored with the persisted data
      session = Session.get(session_name)
      assert session.protocol_version == "2024-11-21"
      assert session.initialized == true
      assert session.client_info["name"] == "restored_client"
    end

    test "restores session with nil log_level using default value" do
      session_id = "legacy_session_with_nil_log_level"
      start_supervised!({Registry, keys: :unique, name: TestSessionRegistryNilLogLevel})

      # Pre-populate store with session data that has nil log_level
      # This simulates sessions saved before log_level was required,
      # or sessions from Redis where log_level was serialized as null
      session_data = %{
        "id" => session_id,
        "protocol_version" => "2024-11-21",
        "initialized" => true,
        "client_info" => %{"name" => "legacy_client"},
        "client_capabilities" => %{"tools" => %{}},
        "log_level" => nil,
        "pending_requests" => %{}
      }

      :ok = MockSessionStore.save(session_id, session_data, [])

      # Start a new session with the same ID - this should NOT crash
      session_name = {:via, Registry, {TestSessionRegistryNilLogLevel, session_id}}

      start_supervised!({Session, session_id: session_id, name: session_name, server_module: TestServer})

      # Verify the session was restored with a default log_level
      session = Session.get(session_name)
      assert session.protocol_version == "2024-11-21"
      assert session.initialized == true
      assert session.client_info["name"] == "legacy_client"
      # log_level should have a default value, not nil
      assert session.log_level
      assert is_binary(session.log_level)
    end

    test "persists sessions without tokens" do
      session_id = "simple_session_789"
      start_supervised!({Registry, keys: :unique, name: TestSessionRegistry3})
      session_name = {:via, Registry, {TestSessionRegistry3, session_id}}

      start_supervised!({Session, session_id: session_id, name: session_name, server_module: TestServer})

      # Mark as initialized to trigger persistence
      Session.mark_initialized(session_name)

      # Verify session was persisted
      {:ok, stored_state} = MockSessionStore.load(session_id, [])
      assert stored_state.initialized == true
      assert stored_state.id == session_id
    end

    test "handles session updates atomically" do
      session_id = "update_session_111"

      # Save initial session to store
      initial_data = %{
        id: session_id,
        log_level: "info",
        initialized: false
      }

      :ok = MockSessionStore.save(session_id, initial_data, [])

      # Perform atomic update
      updates = %{
        log_level: "debug",
        initialized: true
      }

      :ok = MockSessionStore.update(session_id, updates, [])

      # Verify updates were actually persisted to the store
      {:ok, stored_session} = MockSessionStore.load(session_id, [])
      assert stored_session[:log_level] == "debug"
      assert stored_session[:initialized] == true
      assert stored_session[:id] == session_id
    end

    test "lists active sessions" do
      # Create multiple sessions
      session_ids = ["session_a", "session_b", "session_c"]

      for session_id <- session_ids do
        MockSessionStore.save(session_id, %{id: session_id}, [])
      end

      # List active sessions
      {:ok, active} = MockSessionStore.list_active([])
      assert length(active) == 3
      assert Enum.all?(session_ids, &(&1 in active))
    end

    test "deletes sessions from store" do
      session_id = "delete_session_222"

      # Save a session
      :ok = MockSessionStore.save(session_id, %{id: session_id}, [])

      # Verify it exists
      assert {:ok, _} = MockSessionStore.load(session_id, [])

      # Delete it
      :ok = MockSessionStore.delete(session_id, [])

      # Verify it's gone
      assert {:error, :not_found} = MockSessionStore.load(session_id, [])
    end
  end

  describe "session recovery on supervisor startup" do
    setup do
      # Start a test registry
      start_supervised!({Registry, keys: :unique, name: Anubis.Server.Session.StoreTest.TestRegistry})
      :ok
    end

    defmodule TestRegistry do
      @moduledoc false
      alias Anubis.Server.Session.StoreTest.TestRegistry

      def supervisor(:session_supervisor, _server), do: {:via, Registry, {TestRegistry, :supervisor}}
      def server_session(_server, session_id), do: {:via, Registry, {TestRegistry, {:session, session_id}}}

      def whereis_server_session(_server, session_id) do
        case Registry.lookup(TestRegistry, {:session, session_id}) do
          [{pid, _}] -> pid
          [] -> nil
        end
      end
    end

    test "supervisor restores sessions on startup" do
      # Pre-populate store with sessions
      session_ids = ["restored_1", "restored_2"]

      for session_id <- session_ids do
        MockSessionStore.save(
          session_id,
          %{
            id: session_id,
            initialized: true,
            protocol_version: "2024-11-21",
            log_level: "info"
          },
          []
        )
      end

      # Start the supervisor (this should restore sessions)
      start_supervised!({SessionSupervisor, server: TestServer, registry: TestRegistry})

      # Wait a bit for sessions to be restored
      Process.sleep(100)

      # Verify sessions were restored
      for session_id <- session_ids do
        pid = TestRegistry.whereis_server_session(TestServer, session_id)
        assert is_pid(pid)

        # Get the session and verify it has restored data
        session_name = TestRegistry.server_session(TestServer, session_id)
        session = Session.get(session_name)
        assert session.id == session_id
        assert session.initialized == true
      end
    end
  end

  describe "session store configuration" do
    test "works without store configured" do
      # Remove store configuration
      Application.delete_env(:anubis_mcp, :session_store)

      session_id = "no_store_session"
      start_supervised!({Registry, keys: :unique, name: TestSessionRegistry5})
      session_name = {:via, Registry, {TestSessionRegistry5, session_id}}

      # Should still be able to create sessions
      start_supervised!({Session, session_id: session_id, name: session_name, server_module: TestServer})

      # Session should work normally
      Session.mark_initialized(session_name)
      session = Session.get(session_name)
      assert session.initialized == true
    end
  end

  describe "refresh_from_store/2" do
    test "updates initialized flag when store has newer state" do
      session_id = "refresh_test_session"
      start_supervised!({Registry, keys: :unique, name: TestSessionRegistryRefresh})
      session_name = {:via, Registry, {TestSessionRegistryRefresh, session_id}}

      # Start session (will be uninitialized)
      start_supervised!({Session, session_id: session_id, name: session_name, server_module: TestServer})

      # Verify session is not initialized
      session = Session.get(session_name)
      assert session.initialized == false

      # Simulate another server initializing the session (update store directly)
      updated_data = %{
        id: session_id,
        protocol_version: "2024-11-21",
        initialized: true,
        client_info: %{"name" => "remote_client"},
        client_capabilities: %{"tools" => %{}},
        log_level: "info",
        pending_requests: %{}
      }

      :ok = MockSessionStore.save(session_id, updated_data, [])

      # Refresh from store
      refreshed_session = Session.refresh_from_store(session_name, session_id)

      # Should now be initialized with data from store
      assert refreshed_session.initialized == true
      assert refreshed_session.protocol_version == "2024-11-21"
      assert refreshed_session.client_info["name"] == "remote_client"
    end

    test "preserves local pending_requests when refreshing from store" do
      session_id = "refresh_preserve_local"
      start_supervised!({Registry, keys: :unique, name: TestSessionRegistryRefreshLocal})
      session_name = {:via, Registry, {TestSessionRegistryRefreshLocal, session_id}}

      # Start session
      start_supervised!({Session, session_id: session_id, name: session_name, server_module: TestServer})

      # Add a pending request locally
      Session.track_request(session_name, "req_123", "tools/list")

      # Store has different data (no pending_requests since they're not persisted)
      stored_data = %{
        "id" => session_id,
        "initialized" => true,
        "protocol_version" => "2024-11-21",
        "log_level" => "info",
        "pending_requests" => %{}
      }

      :ok = MockSessionStore.save(session_id, stored_data, [])

      # Refresh from store
      refreshed_session = Session.refresh_from_store(session_name, session_id)

      # Should have updated initialized state but preserve local pending_requests
      assert refreshed_session.initialized == true
      assert Map.has_key?(refreshed_session.pending_requests, "req_123")
    end

    test "handles store errors gracefully" do
      session_id = "refresh_error_session"
      start_supervised!({Registry, keys: :unique, name: TestSessionRegistryRefreshError})
      session_name = {:via, Registry, {TestSessionRegistryRefreshError, session_id}}

      # Start session and initialize it locally
      start_supervised!({Session, session_id: session_id, name: session_name, server_module: TestServer})
      Session.mark_initialized(session_name)

      # Delete from store to simulate error scenario (session not in store)
      MockSessionStore.delete(session_id, [])

      # Refresh should keep local state when store load fails
      refreshed_session = Session.refresh_from_store(session_name, session_id)
      assert refreshed_session.initialized == true
    end

    test "works without store configured" do
      # Remove store configuration
      Application.delete_env(:anubis_mcp, :session_store)

      session_id = "no_store_refresh_session"
      start_supervised!({Registry, keys: :unique, name: TestSessionRegistryNoStoreRefresh})
      session_name = {:via, Registry, {TestSessionRegistryNoStoreRefresh, session_id}}

      start_supervised!({Session, session_id: session_id, name: session_name, server_module: TestServer})

      # Should work fine and just return current state
      session = Session.refresh_from_store(session_name, session_id)
      assert session.initialized == false
    end

    test "handles string keys from JSON-decoded store data" do
      session_id = "refresh_string_keys"
      start_supervised!({Registry, keys: :unique, name: TestSessionRegistryStringKeys})
      session_name = {:via, Registry, {TestSessionRegistryStringKeys, session_id}}

      # Start session
      start_supervised!({Session, session_id: session_id, name: session_name, server_module: TestServer})

      # Store data with string keys (as would come from JSON decode)
      stored_data = %{
        "id" => session_id,
        "initialized" => true,
        "protocol_version" => "2024-11-21",
        "client_info" => %{"name" => "json_client"},
        "client_capabilities" => %{},
        "log_level" => "debug"
      }

      :ok = MockSessionStore.save(session_id, stored_data, [])

      # Refresh from store
      refreshed_session = Session.refresh_from_store(session_name, session_id)

      # Should correctly parse string keys
      assert refreshed_session.initialized == true
      assert refreshed_session.protocol_version == "2024-11-21"
      assert refreshed_session.client_info["name"] == "json_client"
      assert refreshed_session.log_level == "debug"
    end
  end
end
