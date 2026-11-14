#include "libssc-sensor-light.c"

typedef struct {
	guint count;
	gfloat value;
} Measurement;

static void
measurement_received (SSCSensorLight *sensor, gfloat intensity, gpointer user_data)
{
	Measurement *measurement = user_data;

	measurement->count++;
	measurement->value = intensity;
}

static void
report_intensity (SSCSensorLight *sensor, gfloat intensity)
{
	SscLightResponse response;
	g_autoptr (GArray) payload = g_array_new (FALSE, FALSE, 1);

	ssc_light_response__init (&response);
	response.n_intensity = 1;
	response.intensity = &intensity;
	response.accuracy = 3;
	g_array_set_size (payload, ssc_light_response__get_packed_size (&response));
	ssc_light_response__pack (&response, (unsigned char *) payload->data);
	report_received (NULL, SSC_MSG_REPORT_MEASUREMENT, 0, 0, payload, sensor);
	while (g_main_context_pending (NULL))
		g_main_context_iteration (NULL, FALSE);
}

static void
light_zero (void)
{
	SSCSensorLight *sensor = g_object_new (SSC_TYPE_SENSOR_LIGHT, NULL);
	Measurement measurement = { 0, -1.0f };

	g_signal_connect (sensor, "measurement", G_CALLBACK (measurement_received), &measurement);
	report_intensity (sensor, 147.0f);
	g_assert_cmpuint (measurement.count, ==, 1);
	g_assert_cmpfloat (measurement.value, ==, 147.0f);
	report_intensity (sensor, 0.0f);
	g_assert_cmpuint (measurement.count, ==, 2);
	g_assert_cmpfloat (measurement.value, ==, 0.0f);
	report_intensity (sensor, -1.0f);
	g_assert_cmpuint (measurement.count, ==, 2);
	g_object_unref (sensor);
}

int
main (int argc, char **argv)
{
	g_test_init (&argc, &argv, NULL);
	g_test_add_func ("/ssc/light/zero-lux", light_zero);
	return g_test_run ();
}
