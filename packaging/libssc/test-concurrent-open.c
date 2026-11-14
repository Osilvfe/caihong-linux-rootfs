#include "libssc-sensor.c"

void
__wrap_ssc_client_send (SSCClient *client, guint64 uid_high, guint64 uid_low,
			guint32 message_id, GArray *protobuf, GCancellable *cancellable,
			GAsyncReadyCallback callback, gpointer user_data)
{
	GTask *task = g_task_new (client, cancellable, callback, user_data);

	g_task_return_boolean (task, TRUE);
	g_object_unref (task);
}

static void
open_complete (GObject *source, GAsyncResult *result, gpointer user_data)
{
	guint *completed = user_data;
	g_autoptr (GError) error = NULL;

	g_assert_true (ssc_sensor_open_finish (SSC_SENSOR (source), result, &error));
	g_assert_no_error (error);
	(*completed)++;
}

static void
drain_context (void)
{
	while (g_main_context_pending (NULL))
		g_main_context_iteration (NULL, FALSE);
}

static void
concurrent_open (gconstpointer user_data)
{
	guint message_id = GPOINTER_TO_UINT (user_data);
	SSCSensor *sensor = g_object_new (SSC_TYPE_SENSOR, NULL);
	SSCSensorPrivate *priv = ssc_sensor_get_instance_private (sensor);
	SSCClient *client = g_object_new (SSC_TYPE_CLIENT, NULL);
	g_autoptr (GArray) payload = g_array_new (FALSE, FALSE, 1);
	guint signal_id = g_signal_lookup ("report", SSC_TYPE_CLIENT);
	SscConfigResponse config;
	guint iteration;

	priv->client = client;
	priv->available = TRUE;
	priv->stream_type = SSC_STREAM_TYPE_ON_CHANGE;
	priv->uid_high = 1;
	priv->uid_low = 2;
	priv->data_type = g_strdup ("test");
	if (message_id == SSC_MSG_RESPONSE_ENABLE_REPORT) {
		ssc_config_response__init (&config);
		g_array_set_size (payload, ssc_config_response__get_packed_size (&config));
		ssc_config_response__pack (&config, (unsigned char *) payload->data);
	}

	for (iteration = 0; iteration < 256; iteration++) {
		guint completed = 0;

		ssc_sensor_open (sensor, NULL, open_complete, &completed);
		ssc_sensor_open (sensor, NULL, open_complete, &completed);
		drain_context ();
		g_signal_emit_by_name (client, "report", message_id,
				      priv->uid_high, priv->uid_low, payload);
		drain_context ();
		g_signal_emit_by_name (client, "report", SSC_MSG_REPORT_MEASUREMENT,
				      priv->uid_high, priv->uid_low, payload);
		g_assert_cmpuint (completed, ==, 2);
		g_assert_false (g_signal_has_handler_pending (client, signal_id, 0, TRUE));
	}
	g_object_unref (sensor);
}

int
main (int argc, char **argv)
{
	g_test_init (&argc, &argv, NULL);
	g_test_add_data_func ("/ssc/concurrent-open/measurement",
		GUINT_TO_POINTER (SSC_MSG_REPORT_MEASUREMENT), concurrent_open);
	g_test_add_data_func ("/ssc/concurrent-open/configuration",
		GUINT_TO_POINTER (SSC_MSG_RESPONSE_ENABLE_REPORT), concurrent_open);
	return g_test_run ();
}
