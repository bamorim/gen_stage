alias Experimental.GenStage

defmodule GenStage.Flow.MapReducer do
  @moduledoc false
  use GenStage

  def init({type, opts, index, trigger, acc, reducer}) do
    {trigger_opts, opts} = Keyword.pop(opts, :trigger, :none)
    start_trigger(trigger_opts)
    partitioned? = match?({GenStage.PartitionDispatcher, _}, opts[:dispatcher])
    consumers = if type == :consumer, do: :none, else: []
    status = %{producers: [], consumers: consumers, done: [], done?: false,
               trigger: trigger, partitioned?: partitioned?}
    {type, {status, index, acc.(), reducer}, opts}
  end

  defp start_trigger({:trigger, time, op, name}) do
    {:ok, _} = :timer.send_interval(time, self(), {:trigger, op, name})
  end
  defp start_trigger(:none) do
    :none
  end

  def handle_subscribe(:producer, _, {_, ref}, {status, index, acc, reducer}) do
    %{producers: producers, done: done} = status
    status = %{status | producers: [ref | producers], done: [ref | done]}
    {:automatic, {status, index, acc, reducer}}
  end

  def handle_subscribe(:consumer, _, {pid, ref}, {status, index, acc, reducer}) do
    %{consumers: consumers} = status

    # If partitioned we do not deliver the notification
    # because the partition dispatcher can buffer those.
    case status do
      %{partitioned?: false, done?: true} ->
        Process.send(pid, {:"$gen_consumer", {self(), ref},
                           {:notification, {:producer, :done}}}, [:noconnect])
      %{} ->
        :ok
    end

    status = %{status | consumers: [ref | consumers]}
    {:automatic, {status, index, acc, reducer}}
  end

  def handle_cancel(_, {_, ref}, {status, index, acc, reducer}) do
    %{producers: producers, consumers: consumers} = status

    cond do
      ref in producers ->
        {events, acc, done, done?} = maybe_notify(status, index, acc, ref)
        status = %{status | producers: List.delete(producers, ref), done: done, done?: done?}
        {:noreply, events, {status, index, acc, reducer}}
      consumers == [ref] ->
        {:stop, :normal, {status, index, acc, reducer}}
      true ->
        status = %{status | consumers: List.delete(consumers, ref)}
        {:noreply, [], {status, index, acc, reducer}}
    end
  end

  def handle_info({:trigger, keep_or_reset, name}, {status, index, acc, reducer}) do
    %{trigger: trigger} = status
    {events, acc} = trigger.(acc, index, keep_or_reset, name)
    {:noreply, events, {status, index, acc, reducer}}
  end
  def handle_info({{_, ref}, {:producer, state}}, {status, index, acc, reducer}) when state in [:halted, :done] do
    {events, acc, done, done?} = maybe_notify(status, index, acc, ref)
    status = %{status | done: done, done?: done?}
    {:noreply, events, {status, index, acc, reducer}}
  end
  def handle_info(_msg, state) do
    {:noreply, [], state}
  end

  def handle_events(events, _from, {status, index, acc, reducer}) do
    {events, acc} = reducer.(events, acc, index)
    {:noreply, events, {status, index, acc, reducer}}
  end

  defp maybe_notify(%{done: [], done?: true}, _index, acc, _ref) do
    {[], acc, [], true}
  end
  defp maybe_notify(%{done: done, done?: false, trigger: trigger, consumers: consumers},
                    index, acc, ref) do
    case List.delete(done, ref) do
      [] when done != [] ->
        {events, acc} = trigger.(acc, index, :keep, {:producer, :done})
        if is_list(consumers) do
          GenStage.async_notify(self(), {:producer, :done})
        end
        {events, acc, [], true}
      done ->
        {[], acc, done, false}
    end
  end
end
