/*
 * instruments — three bench instruments from three vendors on one stdio link.
 *
 * Each speaks SCPI, and each speaks it slightly differently. That is the point
 * of this sample: the differences below are not decoration, they are the three
 * ways a real bench refuses to be uniform.
 *
 *   PSU  (vendor A) — replies in exponent notation:  "+3.30000E+00"
 *   DMM  (vendor B) — replies plain, and terminates with CR LF: "0.412\r\n"
 *   TEMP (vendor C) — replies with the unit attached: "24.8 C"
 *
 * Address a command by prefixing the instrument id, as a VISA resource string
 * would:  psu1:MEAS:VOLT?
 *
 * Build:  cc -O2 -o instruments instruments.c -lm
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static double g_set_volt = 3.30;   /* what the PSU was told to output   */
static int    g_output   = 0;      /* PSU output relay                  */
static double g_load_ohm = 8.0;    /* the load on the bench             */
static double g_temp     = 24.8;   /* what the logger reads             */

/* The measured voltage is not the set voltage. A real supply sags a little
 * under load, and the whole reason an operator watches a meter instead of
 * trusting the knob is that those two numbers are not the same. */
static double measured_volt(void) {
    if (!g_output) return 0.0;
    return g_set_volt - 0.012 * (g_set_volt / g_load_ohm);
}

static double measured_curr(void) {
    if (!g_output) return 0.0;
    return measured_volt() / g_load_ohm;
}

/* Heat follows power. Not a model of anything real — just enough that the
 * temperature moves when the operator turns the output up, so the screen has
 * something honest to show. */
static void settle_temp(void) {
    double p = measured_volt() * measured_curr();
    double target = 24.8 + p * 1.9;
    g_temp += (target - g_temp) * 0.55;
}

static void trim(char *s) {
    size_t n = strlen(s);
    while (n && (s[n-1] == '\n' || s[n-1] == '\r' || s[n-1] == ' ')) s[--n] = 0;
}

int main(void) {
    char line[256];
    setvbuf(stdout, NULL, _IOLBF, 0);

    while (fgets(line, sizeof line, stdin)) {
        trim(line);
        if (!line[0]) continue;

        char *colon = strchr(line, ':');
        if (!colon) { printf("ERR no instrument\n"); continue; }
        *colon = 0;
        const char *who = line;
        const char *cmd = colon + 1;

        /* ---- PSU, vendor A: exponent notation ------------------------- */
        if (strcmp(who, "psu1") == 0) {
            if (strcmp(cmd, "*IDN?") == 0)
                printf("VENDOR-A,PSU-3010,SN%06d,1.4\n", 421337);
            else if (strcmp(cmd, "MEAS:VOLT?") == 0)
                printf("%+.5E\n", measured_volt());
            else if (strcmp(cmd, "MEAS:CURR?") == 0)
                printf("%+.5E\n", measured_curr());
            else if (strncmp(cmd, "SOUR:VOLT ", 10) == 0) {
                double v = atof(cmd + 10);
                /* The supply clamps to its own rating whatever it is told.
                 * The screen above may ask for 30 V; this box goes to 12. */
                if (v < 0) v = 0;
                if (v > 12.0) v = 12.0;
                g_set_volt = v;
                settle_temp();
                printf("OK\n");
            } else if (strcmp(cmd, "OUTP ON") == 0)  { g_output = 1; settle_temp(); printf("OK\n"); }
            else if   (strcmp(cmd, "OUTP OFF") == 0) { g_output = 0; settle_temp(); printf("OK\n"); }
            else printf("ERR unsupported %s\n", cmd);
        }
        /* ---- DMM, vendor B: plain decimal, CRLF terminated ------------- */
        else if (strcmp(who, "dmm1") == 0) {
            if (strcmp(cmd, "*IDN?") == 0)
                printf("VENDOR-B,DMM-71,SN%06d,2.0\r\n", 90210);
            else if (strcmp(cmd, "MEAS:CURR?") == 0)
                printf("%.4f\r\n", measured_curr());
            else if (strcmp(cmd, "MEAS:VOLT?") == 0)
                printf("%.4f\r\n", measured_volt());
            else printf("ERR unsupported %s\r\n", cmd);
        }
        /* ---- TEMP logger, vendor C: value with unit attached ----------- */
        else if (strcmp(who, "temp1") == 0) {
            if (strcmp(cmd, "*IDN?") == 0)
                printf("VENDOR-C,TL-4,SN%06d,0.9\n", 5150);
            else if (strcmp(cmd, "MEAS:TEMP?") == 0) {
                settle_temp();
                printf("%.1f C\n", g_temp);
            } else printf("ERR unsupported %s\n", cmd);
        }
        else printf("ERR no instrument %s\n", who);
    }
    return 0;
}
