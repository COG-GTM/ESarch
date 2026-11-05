package io.pivotal.refarch.cqrs.trader.app.query.company;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.pivotal.refarch.cqrs.trader.coreapi.company.CompanyByIdQuery;
import io.pivotal.refarch.cqrs.trader.coreapi.company.CompanyCreatedEvent;
import io.pivotal.refarch.cqrs.trader.coreapi.company.CompanyId;
import org.junit.*;
import org.junit.runner.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.test.context.junit4.SpringRunner;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import static org.junit.Assert.*;

/**
 * Runs the query outside a transaction, like the query bus does with spring.jpa.open-in-view=false, so the result
 * has to be fully loaded when QueryController serialises it.
 */
@RunWith(SpringRunner.class)
@DataJpaTest
@Transactional(propagation = Propagation.NOT_SUPPORTED)
public class CompanyEventHandlerIntegrationTest {

    @Autowired
    private CompanyViewRepository companyRepository;

    private CompanyEventHandler testSubject;

    @Before
    public void setUp() {
        companyRepository.deleteAll();
        testSubject = new CompanyEventHandler(companyRepository);
    }

    @Test
    public void testFindCompanyByIdReturnsASerialisableView() throws Exception {
        CompanyId companyId = new CompanyId();
        testSubject.on(new CompanyCreatedEvent(companyId, "Pivotal", 1337L, 42L));

        CompanyView result = testSubject.find(new CompanyByIdQuery(companyId));

        JsonNode json = new ObjectMapper().readTree(new ObjectMapper().writeValueAsString(result));
        assertEquals(companyId.getIdentifier(), json.get("identifier").asText());
        assertEquals("Pivotal", json.get("name").asText());
        assertEquals(1337L, json.get("value").asLong());
        assertEquals(42L, json.get("amountOfShares").asLong());
    }

    @Test
    public void testFindCompanyByIdReturnsNullForNonExistingId() {
        assertNull(testSubject.find(new CompanyByIdQuery(new CompanyId("non-existing-id"))));
    }
}
